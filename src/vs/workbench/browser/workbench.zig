//! Transitional terminal workbench composition root, not yet the faithful
//! workbench.ts port. The terminal host owns rendering and input routing;
//! this file still contains feature wiring and host state. See
//! docs/workbench-audit.md for the remaining upstream ownership map.
//!
//! Every group gets a tab row and an editor pane, groups are arranged in an
//! oriented split tree, and src/tui/workbench.zig composites visible panes into
//! one frame before encoding the ANSI diff. Each
//! tab owns a persistent `View`, so switching tabs or groups keeps scroll
//! position and decorations. The port keeps Grid's branch-demotion behavior
//! when a group empties, its sash resize, and tab drag/drop into a group,
//! onto a pane edge, or onto a tab strip with an insertion preview; the full
//! N-ary branch model is not ported yet.
//!
//! Like VS Code's editorBorder.css, the rounded outline encloses the entire
//! editor area. The split tree draws straight sashes inside it. Cell borders
//! draw both on cell edges; the glyph fallback reserves a cell for each line.
//! The sidebar and bottom panel use the same rounded frame treatment, adapting
//! the outlines in upstream's `floatingPanels.css` to the terminal grid.
//! The SCM history hover adapts the rounded workbench hover from
//! `src/vs/platform/hover/browser/hover.css` to the terminal cell grid.
//!
//! A split duplicates the active input into the new group, matching upstream
//! `EditorGroupView.copyEditor`: both panes show the same `EditorDocument` and
//! share its text model, undo history and dirty state, while wrapping, cursors,
//! scroll and folding are independent per view. `workbench.action.splitEditor`
//! follows `workbench.editor.openSideBySideDirection`; the Left/Right/Up/Down
//! command variants place the copy on the requested side.
//!
//! Text reads, color themes, keybindings and image previews post completion
//! to the window thread. Startup and session restore can open files synchronously.
//! Explorer and Markdown workers still have separate completion paths.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ui = @import("ui");
const editor_css = @import("../../editor/browser/editorCss.zig");
const grid_mod = @import("../../base/browser/ui/grid/grid.zig");
const sash_css = @import("../../base/browser/ui/sash/sash_css.zig");
const editor_drop_target = @import("./parts/editor/editorDropTarget.zig");
const editor_tabs_control = @import("./parts/editor/editorTabsControl.zig");
const editor_group_view = @import("./parts/editor/editorGroupView.zig");
const editor_group_watermark = @import("./parts/editor/editorGroupWatermark.zig");
const editor_part = @import("./parts/editor/editorPart.zig");
const Tab = @import("./parts/editor/editorPane.zig").Tab;
const FileEditorInput = @import("../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const FileEditorSerializer = @import("../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorSerializer;
const editor_factory = @import("../common/editor/editorFactory.zig");
const tui_editor_mod = @import("../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
const Editor = tui_editor_mod.Editor;
const TextEdit = @import("../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").TextEdit;
const terminal_editor_config = @import("../../editor/browser/config/terminalEditorConfiguration.zig");
const editor_options = @import("../../editor/common/config/editorOptions.zig");
const tab_bar = @import("./parts/editor/multiEditorTabsControl.zig");
const file_icon = @import("../services/themes/browser/fileIconThemeData.zig");
const Sidebar = @import("../contrib/files/browser/views/explorerView.zig").Sidebar;
const activity_bar_mod = @import("./parts/activitybar/activitybarPart.zig");
const ActivityBarPart = @import("./parts/activitybar/activitybarPart.zig").ActivityBarPart;
const sidebar_part_mod = @import("./parts/sidebar/sidebarPart.zig");
const SidebarPart = sidebar_part_mod.SidebarPart;
const layout_service_mod = @import("../services/layout/browser/layoutService.zig");
const workbench_layout = @import("./layout.zig");
const Layout = workbench_layout.Layout;
const code_editor_service = @import("../../editor/browser/services/codeEditorService.zig");
const CodeEditorService = @import("../services/editor/browser/codeEditorService.zig").CodeEditorService;
const WorkbenchGrid = workbench_layout.WorkbenchGrid;
const statusbar_mod = @import("./parts/statusbar/statusbarPart.zig");
const statusbar_model_mod = @import("./parts/statusbar/statusbarModel.zig");
const StatusbarService = statusbar_mod.StatusbarService;
const EntryAccessor = statusbar_mod.EntryAccessor;
const statusbar_types = @import("../services/statusbar/browser/statusbar.zig");
const ActivityService = @import("../services/activity/browser/activityService.zig").ActivityService;
const history_mod = @import("../services/history/browser/historyService.zig");
const HistoryService = history_mod.HistoryService;
const commands_mod = @import("./commands.zig");
const CommandRegistry = commands_mod.CommandRegistry;
const SimpleBrowserManager = @import("../../../extensions/simple-browser/src/simpleBrowserManager.zig").SimpleBrowserManager;
const terminal_platform = @import("../../platform/terminal/common/terminal.zig");
const terminal_profiles = @import("../../platform/terminal/node/terminalProfiles.zig");
const quick_access_mod = @import("./quickaccess.zig");
const QuickAccessService = quick_access_mod.QuickAccessService;
const editor_status_mod = @import("./parts/editor/editorStatus.zig");
const EditorStatus = editor_status_mod.EditorStatus;
const workspace_context = @import("../services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const configuration_mod = @import("../services/configuration/browser/configurationService.zig");
const workbench_configuration = @import("./workbenchConfiguration.zig");
const zen_mode_contribution = @import("./workbench.zenMode.contribution.zig");

const ConfigurationService = configuration_mod.ConfigurationService;
const file_watcher_service_mod = @import("../../platform/files/node/watcher/fileWatcherService.zig");
const FileWatcherService = file_watcher_service_mod.FileWatcherService;
const contributions_mod = @import("../common/contributions.zig");
const workspace_watcher_mod = @import("../contrib/files/browser/workspaceWatcher.zig");
const WorkspaceWatcher = workspace_watcher_mod.WorkspaceWatcher;
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
const syntax_theme_mod = @import("../../editor/standalone/browser/standaloneThemeService.zig");
const textmate_background_mod = @import("../services/textMate/browser/backgroundTokenization/threadedBackgroundTokenizerFactory.zig");
const TokenizationRegistry = @import("../../editor/common/tokenizationRegistry.zig").TokenizationRegistry;
const theme_colors_mod = @import("./themeColors.zig");
const SettingsWatcher = configuration_mod.SettingsWatcher;
const IDisposable = @import("../../base/common/lifecycle.zig").IDisposable;
const breadcrumbs_model = @import("./parts/editor/breadcrumbsModel.zig");
const breadcrumbs_picker = @import("./parts/editor/breadcrumbsPicker.zig");
const breadcrumbs_control_mod = @import("./parts/editor/breadcrumbsControl.zig");
const BreadcrumbsControl = breadcrumbs_control_mod.BreadcrumbsControl;
const BreadcrumbsSelection = breadcrumbs_control_mod.Selection;
const BreadcrumbsSelectMode = breadcrumbs_control_mod.SelectMode;
const BreadcrumbsAnchor = breadcrumbs_control_mod.Anchor;
const outline_service_mod = @import("../services/outline/browser/outlineService.zig");
const OutlineService = outline_service_mod.OutlineService;
const outline_mod = @import("../services/outline/browser/outline.zig");
const OutlineEditor = outline_mod.OutlineEditor;
const IOutlineCreator = outline_mod.IOutlineCreator;
const DocumentSymbolsOutlineCreator = @import("../contrib/codeEditor/browser/outline/documentSymbolsOutline.zig").DocumentSymbolsOutlineCreator;
const outline_model = @import("../../editor/contrib/documentSymbols/browser/outlineModel.zig");
const OutlineModel = outline_model.OutlineModel;
const Emitter = @import("../../base/common/event.zig").Emitter;
const lifecycle_mod = @import("../services/lifecycle/common/lifecycle.zig");
const ServiceCollection = @import("../../platform/instantiation/common/serviceCollection.zig").ServiceCollection;
const InstantiationService = @import("../../platform/instantiation/common/instantiationService.zig").InstantiationService;
const ServicesAccessor = @import("../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const outline_pane_mod = @import("../contrib/outline/browser/outlinePane.zig");
const OutlinePane = outline_pane_mod.OutlinePane;
const outline_contrib = @import("../contrib/outline/browser/outline.zig");
const OutlineSortOrder = outline_contrib.OutlineSortOrder;
const quick_input_common = @import("../../platform/quickinput/common/quickInput.zig");
const QuickPickItem = quick_input_common.QuickPickItem;
const QuickPick = @import("../../platform/quickinput/browser/quickInput.zig").QuickPick;
const dialogs = @import("../../platform/dialogs/common/dialogs.zig");
const markers_common = @import("../contrib/markers/common/markers.zig");
const MarkersStatusBar = @import("../contrib/markers/browser/markersStatusBar.zig").MarkersStatusBar;
const pane_composite_mod = @import("./parts/paneCompositePart.zig");

/// Upstream `Markers.MARKERS_CONTAINER_ID` and `TERMINAL_VIEW_ID`.
const PROBLEMS_CONTAINER_ID = markers_common.Markers.MARKERS_CONTAINER_ID;
const TERMINAL_CONTAINER_ID = "terminal";
const MarkersView = @import("../contrib/markers/browser/markersView.zig").MarkersView;
const panel_part_mod = @import("./parts/panel/panelPart.zig");
const PanelPart = panel_part_mod.PanelPart;
const views_mod = @import("../common/views.zig");
const view_descriptor_service_mod = @import("../services/views/browser/viewDescriptorService.zig");
const ViewDescriptorService = view_descriptor_service_mod.ViewDescriptorService;
const range_highlight_mod = @import("./codeeditor.zig");
const RangeHighlightDecorations = range_highlight_mod.RangeHighlightDecorations;

const search_editor = @import("../contrib/searchEditor/browser/searchEditor.zig");
const search_editor_serialization = @import("../contrib/searchEditor/browser/searchEditorSerialization.zig");
const search_editor_input_mod = @import("../contrib/searchEditor/browser/searchEditorInput.zig");
const SearchEditorInput = search_editor_input_mod.SearchEditorInput;
const search_command_ids = @import("../contrib/search/common/constants.zig").SearchCommandIds;
const search_view_mod = @import("../contrib/search/browser/searchViewTerminal.zig");
const SearchView = search_view_mod.SearchView;
const search_widget_mod = @import("../contrib/search/browser/searchWidget.zig");
const search_service_mod = @import("../services/search/common/searchService.zig");
const SearchService = search_service_mod.SearchService;
const search_types = @import("../services/search/common/search.zig");
const glob = @import("../../base/common/glob.zig");
const FileContentProvider = search_types.FileContentProvider;
const replace_service_mod = @import("../contrib/search/browser/replaceService.zig");
const replace_types = replace_service_mod;
const search_configuration = @import("../contrib/search/common/searchConfiguration.zig");
const tree = @import("../contrib/search/browser/searchTreeModel/searchTreeCommon.zig");
const group_mod = @import("../common/editor/editorGroupModel.zig");
const editor_service_mod = @import("../services/editor/browser/editorService.zig");
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
const references_model = @import("../../editor/contrib/gotoSymbol/browser/referencesModel.zig");
const ReferencesModel = references_model.ReferencesModel;
const go_to_commands = @import("../../editor/contrib/gotoSymbol/browser/goToCommands.zig");
const goto_symbol_quick_access = @import("../contrib/codeEditor/browser/quickaccess/gotoSymbolQuickAccess.zig");
const hover_operation = @import("../../editor/contrib/hover/browser/hoverOperation.zig");
const hover_types = @import("../../editor/contrib/hover/browser/hoverTypes.zig");
const sticky_actions = @import("../../editor/contrib/stickyScroll/browser/stickyScrollActions.zig");
const strings = @import("../../base/common/strings.zig");
const MarkdownPreviewConfig = @import("../contrib/markdown/browser/markdownPreviewConfig.zig").MarkdownPreviewConfig;
const media_preview = @import("../contrib/mediaPreview/common/mediaPreview.zig");
const ImagePreviewEditorInput = @import("../contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInput;
const ImagePreviewEditorInputSerializer = @import("../contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInputSerializer;
const MediaPreviewStatus = @import("../contrib/mediaPreview/browser/mediaPreviewStatusBar.zig").MediaPreviewStatus;
const media_actions = @import("../contrib/mediaPreview/browser/mediaPreviewActions.zig");
const std_uri = @import("../../base/common/stdUri.zig");
const MarkerService = @import("../../platform/markers/common/markerService.zig").MarkerService;
const MarkerChangeEvent = @import("../../platform/markers/common/markerService.zig").MarkerChangeEvent;
const MarkerDecorationsService = @import("../../editor/common/services/markerDecorationsService.zig").MarkerDecorationsService;
const markers_mod = @import("../../platform/markers/common/markers.zig");
const SnippetCompletionProvider = @import("../contrib/snippets/browser/snippetCompletionProvider.zig").SnippetCompletionProvider;
const WordBasedCompletionProvider = @import("../../editor/contrib/suggest/browser/wordBasedSuggestions.zig").WordBasedCompletionProvider;
const Position = @import("../../editor/common/core/position.zig").Position;
const Selection = @import("../../editor/common/core/selection.zig").Selection;
const EOL = @import("../../editor/common/core/misc/eolCounter.zig").EOL;
const encoding_mod = @import("../services/textfile/common/encoding.zig");
const SearchOption = @import("../contrib/search/browser/searchWidget.zig").Option;
const terminal_service_mod = @import("../contrib/terminal/browser/terminalService.zig");
const terminal_configuration = @import("../contrib/terminal/common/terminalConfiguration.zig");
const terminal_actions = @import("../contrib/terminal/browser/terminalActions.zig");
const terminal_common = @import("../contrib/terminal/common/terminal.zig");
const terminal_panel = @import("../contrib/terminal/browser/terminalTabbedView.zig");
const terminal_tabs = @import("../contrib/terminal/browser/terminalTabsList.zig");
const terminal_input_mod = @import("../contrib/terminal/browser/terminalInput.zig");
const diff_widget_mod = @import("../../editor/browser/widget/diffEditor/diffEditorWidget.zig");
const git_model_mod = @import("../../../extensions/git/src/model.zig");
const git_mod = @import("../../../extensions/git/src/git.zig");
const scm_contribution = @import("../contrib/scm/browser/scm.contribution.zig");
const SCMContribution = scm_contribution.SCMContribution;
const scm_common = @import("../contrib/scm/common/scm.zig");
const repository_mod = @import("../../../extensions/git/src/repository.zig");
const scm_view_mod = @import("../contrib/scm/browser/scmViewPane.zig");
const scm_history_view_mod = @import("../contrib/scm/browser/scmHistoryViewPane.zig");
const scm_common_history = @import("../contrib/scm/common/history.zig");
const view_container_model_mod = @import("../services/views/common/viewContainerModel.zig");
const view_pane_container_mod = @import("./parts/views/viewPaneContainer.zig");
const storage_mod = @import("../../platform/storage/common/storage.zig");
const TerminalService = terminal_service_mod.TerminalService;

pub const TabKeyResult = enum { unhandled, handled, quit };
pub const SplitDirection = grid_mod.Orientation;
/// Target selector shared by the move/copy editor and group commands, port of
/// upstream `SelectedEditorsMoveCopyArguments.to`.
pub const GroupTarget = enum { first, last, previous, next, left, right, up, down };
pub const GroupLocation = editor_groups.GroupLocation;
pub const Focus = enum { editor, sidebar, statusbar, breadcrumbs, terminal, problems };

/// Handles for the context keys the workbench maintains. User keybindings use
/// them in `when` clauses; keys the terminal cannot know stay undefined, which
/// evaluates to false (e.g. `treeFindOpen`).
const ContextKeyHandles = struct {
    editor_focus: context_key_mod.IContextKey,
    editor_text_focus: context_key_mod.IContextKey,
    editor_lang_id: context_key_mod.IContextKey,
    active_custom_editor_id: context_key_mod.IContextKey,
    input_focus: context_key_mod.IContextKey,
    list_focus: context_key_mod.IContextKey,
    side_bar_focus: context_key_mod.IContextKey,
    status_bar_focus: context_key_mod.IContextKey,
    terminal_focus: context_key_mod.IContextKey,
    panel_focus: context_key_mod.IContextKey,
    active_panel: context_key_mod.IContextKey,
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
    legacy_editor_read_only: context_key_mod.IContextKey,
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
pub const DiffRef = git_mod.DiffRef;

const SymbolActionContext = struct {
    workbench: *Workbench,
    action: *const go_to_commands.ActionDescriptor,
};

const LayoutNode = grid_mod.Node(*GroupPane);

/// One editor group in the terminal editor part: the ported group view holds
/// the group model, the tabs (views/controllers), the tab-strip hit cache and
/// the cell rectangle it occupies.
pub const GroupPane = editor_group_view.EditorGroupView(*Tab);

const ScmDiscardDialog = struct {
    workbench: *Workbench,
    request: ScmDiscardRequest,
};

const ScmDiscardRequest = struct {
    root: []u8,
    path: []u8,
    untracked: bool,

    fn deinit(self: ScmDiscardRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.path);
    }
};

const editor_mod = @import("../common/editor.zig");

const text_files = @import("../services/textfile/common/textFileService.zig");
const TextFileRead = text_files.TextFileRead;
const OpenJob = struct {
    read: *TextFileRead,
    options: Workbench.OpenOptions,
};

const context_menus = @import("../../platform/contextview/browser/contextMenuService.zig");
const Menu = context_menus.Menu;
const MenuAnchor = context_menus.Anchor;
const MenuActionContext = struct {
    workbench: *Workbench,
    group_id: ?editor_mod.GroupIdentifier = null,
    tabs: []const *Tab = &.{},
    container_id: ?[]const u8 = null,
    view_id: ?[]const u8 = null,
};

pub const IWorkbenchOptions = struct {
    /// Class IDs in the terminal document stylesheet.
    extra_classes: []const u16 = &.{},
    reset_layout: bool = false,
};

const views_service = @import("../services/views/common/viewsService.zig");

/// The terminal Search view is a single pane in its activity container.
const WindowViews = struct {
    workbench: *Workbench,

    pub fn interface(self: *WindowViews) views_service.IViewsService {
        return .{ .context = self, .get_active_view = getActiveView, .get_view = getView, .open_view = openView };
    }

    fn getActiveView(context: *anyopaque, id: []const u8) ?*anyopaque {
        const self: *WindowViews = @ptrCast(@alignCast(context));
        const active = self.workbench.sidebar_part.pane.active_id orelse return null;
        if (std.mem.eql(u8, id, SearchView.ID))
            return if (std.mem.eql(u8, active, "search")) self.workbench.search_view else null;
        const local_id: []const u8 = if (std.mem.eql(u8, id, scm_view_mod.SCMViewPane.ID)) "changes" else if (std.mem.eql(u8, id, scm_history_view_mod.SCMHistoryViewPane.ID)) "graph" else return null;
        const container = self.workbench.view_descriptor_service.getViewContainerByViewId(local_id) orelse return null;
        return if (std.mem.eql(u8, active, container.container.id)) getView(context, id) else null;
    }

    fn getView(context: *anyopaque, id: []const u8) ?*anyopaque {
        const self: *WindowViews = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, id, SearchView.ID)) return self.workbench.search_view;
        if (std.mem.eql(u8, id, scm_view_mod.SCMViewPane.ID)) return self.workbench.scm.changes;
        if (std.mem.eql(u8, id, scm_history_view_mod.SCMHistoryViewPane.ID)) return self.workbench.scm.history;
        return null;
    }

    fn openView(context: *anyopaque, id: []const u8, focus: bool) !?*anyopaque {
        const self: *WindowViews = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, id, SearchView.ID)) return null;
        try self.workbench.openActivity("search", focus);
        return self.workbench.search_view;
    }
};

pub const Workbench = struct {
    const WindowTimer = @import("../../base/common/async.zig").WindowTimer;
    startup_window: ?struct { parent: *ui.Node, options: IWorkbenchOptions, has_previous_state: bool },
    restore_timer: ?*WindowTimer,
    code_editors: CodeEditorService,
    window_views: WindowViews,
    views_api: views_service.IViewsService,
    code_editor_api: code_editor_service.ICodeEditorService,
    editors: editor_service_mod.EditorService,
    editor_api: @import("../services/editor/common/editorService.zig").IEditorService,
    editor_groups_api: editor_groups.IEditorGroupsService,
    allocator: Allocator,
    view_factory: @import("parts/editor/editorPane.zig").EditorViewFactory,
    io: Io,
    /// Io used to run interactive file/dir/network work off the TUI thread.
    /// It is a separate instance from `io` with `async_limit = .unlimited` so
    /// `Io.async` never falls back to running a blocking read inline on the
    /// TUI thread just because the default pool is busy. `io` remains the
    /// terminal/synchronous-startup instance.
    async_io_state: Io.Threaded,
    async_io: Io,
    disk_files: @import("../../platform/files/common/fileService.zig").DiskFileService,
    text_file_service: text_files.TextFileService,
    /// The single interactive open currently in flight. A newer request
    /// supersedes it; the generation is checked again when the result lands.
    pending_open: ?OpenJob = null,
    reload_jobs: std.array_list.Managed(*TextFileRead),
    cols: usize,
    rows: usize,

    service: *editor_groups.EditorGroupsService,
    part: *editor_part.EditorPart(GroupPane),
    frame: ui.Frame,
    editor_surface: *ui.Surface,

    editor_drop_target: editor_drop_target.EditorDropTarget,
    sidebar: ?*Sidebar = null,
    /// Port of the Explorer viewlet's view-pane container: the Explorer tree
    /// and the Outline view are stacked sections in the same SidebarPart.
    explorer_container: ?*view_pane_container_mod.ViewPaneContainer = null,
    explorer_view_model: ?*view_container_model_mod.ViewContainerModel = null,
    explorer_panes: ?[]view_pane_container_mod.Pane = null,
    window_events: @import("../../base/common/windowDispatch.zig").Queue,
    search_view: ?*SearchView = null,
    search_service: ?*SearchService = null,
    layout: Layout,
    activity_bar_part: ActivityBarPart,
    sidebar_part: SidebarPart,
    panel_part: PanelPart,
    view_containers_registry: views_mod.ViewContainersRegistry,
    view_descriptor_service: ViewDescriptorService,
    statusbar: StatusbarService,
    notification_storage: storage_mod.InMemoryStorageService,
    notification_service: *@import("../services/notification/common/notificationService.zig").NotificationService,
    notification_api: @import("../../platform/notification/common/notification.zig").INotificationService,
    notification_controller: ?*@import("parts/notifications/notificationsCommands.zig").NotificationsController = null,
    images: ui.image.Runtime,
    /// Desired OSC 22 mouse pointer shape for the next frame. Only the
    /// composited renderer writes it; pane surfaces resolve shapes but never
    /// emit them.
    pointer: ui.Pointer = .default,
    pointer_state: ui.pointer.State = .{},
    pointer_shapes: bool = false,
    media_status: ?*MediaPreviewStatus = null,
    activity_service: ActivityService,
    editor_status: ?*EditorStatus = null,
    status_hint_accessor: ?EntryAccessor = null,
    /// Stable storage for the transient "Opening ..." status hint; the
    /// status-bar entry keeps the slice.
    status_hint_buf: [256]u8 = undefined,
    /// Branch-aware placeholder for the Source Control commit input.
    markers_status: ?*MarkersStatusBar = null,
    problems_view: ?MarkersView = null,
    marker_listener: ?Emitter(MarkerChangeEvent).ListenerId = null,
    range_highlights: ?*RangeHighlightDecorations = null,
    workspace: *WorkspaceContextService,
    configuration: ?*ConfigurationService,
    settings_watcher: ?*SettingsWatcher = null,
    /// Window file service shared by workspace and configuration watchers.
    file_watcher_service: ?*FileWatcherService = null,
    /// Port of the `workspaceWatcher.ts` contribution. Instantiated by the
    /// upstream `AfterRestored` phase, after the first frame.
    workspace_watcher: ?*WorkspaceWatcher = null,
    contributions: contributions_mod.WorkbenchContributions,
    lifecycle: @import("../services/lifecycle/common/lifecycleService.zig").LifecycleService,
    user_settings_paths: []const []const u8,
    history: HistoryService,
    view_state_storage: ?view_container_model_mod.ViewDescriptorsState = null,
    sidebar_action_anchor: ?MenuAnchor = null,
    commands: CommandRegistry,
    working_copy_service: WorkingCopyService,
    tab_service: ?*keybinding_service.KeybindingService,
    tab_command_result: ?TabKeyResult = null,
    global_service: ?*keybinding_service.KeybindingService,
    statusbar_service: ?*keybinding_service.KeybindingService,
    context_keys: ?*context_key_mod.ContextKeyService,
    context_key_handles: ?ContextKeyHandles,
    workbench_context: @import("contextkeys.zig").WorkbenchContextKeysHandler,
    terminal_context: @import("../contrib/terminal/browser/terminalContextKeys.zig").TerminalContextKeysHandler,
    terminal_action_services: terminal_actions.TerminalActionServices,
    user_keybindings: *user_keybindings_mod.UserKeybindingsLoader,
    theme_service: ?*theme_service_mod.ThemeService,
    syntax_theme: syntax_theme_mod.SyntaxTheme,
    syntax_theme_ready: bool,
    /// Process-wide async TextMate tokenizer. Created lazily by
    /// `enableAsyncTokenization`, so tests keep the synchronous fallback.
    textmate_background: ?*textmate_background_mod.Factory = null,
    theme_scheme_host: TerminalColorSchemeHost,
    theme_palette: ?*theme_colors_mod.ThemeColors,
    quick_access: *QuickAccessService,
    quick_input_api: @import("../../platform/quickinput/common/quickInput.zig").IQuickInputService,
    simple_browser: SimpleBrowserManager,
    outline_service: OutlineService,
    services: ServiceCollection,
    instantiation: InstantiationService,
    layout_api: layout_service_mod.IWorkbenchLayoutService,
    lifecycle_api: lifecycle_mod.ILifecycleService,
    on_will_shutdown: Emitter(lifecycle_mod.WillShutdownEvent),
    on_did_shutdown: Emitter(void),
    /// Terminal Outline side panel (`outline` view container).
    outline_view: ?*OutlinePane = null,
    breadcrumbs: breadcrumbs_control_mod.BreadcrumbsControlCollection,
    home_path: ?[]u8 = null,
    breadcrumbs_arena: std.heap.ArenaAllocator,
    navigation_arena: std.heap.ArenaAllocator,
    builtin_host: *@import("../api/browser/builtinExtensionHost.zig").BuiltinExtensionHost,
    references_view_registered: bool,
    references_view: @import("../../../extensions/references-view/referencesView.zig").SymbolsTree,
    pending_references: ?*ReferencesModel = null,
    symbol_picker: ?struct {
        tab: *Tab,
        subscription: ?IDisposable = null,
        outline: ?*OutlineModel = null,
    } = null,
    pending_symbols: ?[]goto_symbol_quick_access.Entry = null,
    symbol_action_contexts: [go_to_commands.actions.len]SymbolActionContext = undefined,
    frame_scheduler: ?struct {
        context: *anyopaque,
        request: *const fn (*anyopaque) void,
    } = null,
    /// Anchored breadcrumb picker (upstream context-view tree). The popup
    /// borrows its item strings and symbol handles from `breadcrumbs_arena`.
    breadcrumb_popup: ?*breadcrumbs_picker.Picker = null,
    context_menu_service: context_menus.ContextMenuService,
    menu_service: @import("../../platform/actions/common/menuService.zig").MenuService,
    hovered_tab: ?*Tab = null,
    hovered_pane: ?*GroupPane = null,
    hovered_title_action_pane: ?*GroupPane = null,
    /// Pointer capture for the side-bar divider drag.
    hovered_sash: ?union(enum) { workbench: WorkbenchGrid.Sash, editor: *LayoutNode } = null,
    declarative: ?*const extensions_registry.Registry = null,
    json_client: ?*json_language.Client = null,
    language_features: ?*LanguageFeaturesService = null,
    marker_service: ?*MarkerService = null,
    marker_decorations: ?*MarkerDecorationsService = null,
    snippet_provider: SnippetCompletionProvider,
    snippet_registration: ?IDisposable = null,
    word_completion_provider: ?*WordBasedCompletionProvider = null,
    word_completion_registration: ?IDisposable = null,
    outline_creator: ?DocumentSymbolsOutlineCreator = null,
    focus: Focus = .editor,
    focus_subscriptions: [4]?@import("../../base/common/event.zig").SignalSubscription = .{ null, null, null, null },
    terminal_focus_subscription: ?@import("../../base/common/event.zig").SignalSubscription = null,
    is_pasting: bool = false,
    terminal_service: ?*TerminalService = null,
    terminal_input: terminal_input_mod.Encoder = .{},
    terminal_tabbed_view: terminal_panel.TerminalTabbedView = .{},
    suppress_global_command: bool = false,
    git_model: git_model_mod.Model,
    scm: SCMContribution,
    scm_view_model: ?*view_container_model_mod.ViewContainerModel = null,
    scm_container: ?*view_pane_container_mod.ViewPaneContainer = null,
    /// Set when the quit confirmation commits to closing the window.
    quit_requested: bool = false,
    /// The modal save confirmation, if one is open.
    dialog_service: @import("../services/dialogs/common/dialogService.zig").DialogService,
    dialog_handler: *@import("parts/dialogs/dialog.web.contribution.zig").DialogHandlerContribution,
    dialog_api: dialogs.IDialogService,

    pub const PreviousState = struct {
        data: editor_groups.SerializedEditorPart,
        registry: *editor_factory.EditorFactoryRegistry,
    };

    /// Constructs the window. The host owns the surface and the option slices
    /// through startup. Service instances supplied by the host remain borrowed.
    pub fn init(allocator: Allocator, io: Io, view_factory: @import("parts/editor/editorPane.zig").EditorViewFactory, surface: *ui.Surface, services: *ServiceCollection, options: IWorkbenchOptions, state: ?PreviousState) !*Workbench {
        const parent = surface.document().root orelse return error.MissingWorkbenchParent;
        const self = try allocator.create(Workbench);
        errdefer allocator.destroy(self);

        self.* = undefined;
        self.startup_window = .{ .parent = parent, .options = options, .has_previous_state = state != null };
        self.restore_timer = null;
        self.references_view_registered = false;
        self.allocator = allocator;
        self.view_factory = view_factory;
        self.io = io;
        self.async_io_state = Io.Threaded.init(allocator, .{
            .async_limit = .unlimited,
            .environ = asyncEnviron(),
        });
        errdefer self.async_io_state.deinit();
        self.async_io = self.async_io_state.io();
        self.disk_files = .init(allocator, self.async_io);
        errdefer self.disk_files.deinit();
        self.text_file_service = .init(allocator, &self.disk_files);
        errdefer self.text_file_service.deinit();
        self.pending_open = null;
        self.reload_jobs = std.array_list.Managed(*TextFileRead).init(allocator);
        self.editor_surface = surface;
        self.cols = surface.document().cols;
        self.tab_service = null;
        self.global_service = null;
        self.statusbar_service = null;
        self.context_keys = null;
        self.context_key_handles = null;
        self.theme_service = null;
        self.syntax_theme = .{};
        self.syntax_theme_ready = false;
        self.textmate_background = null;
        self.theme_scheme_host = .{};
        self.theme_palette = null;
        self.rows = surface.document().rows;
        self.is_pasting = false;
        self.terminal_service = null;
        self.terminal_input = .{};
        self.terminal_tabbed_view = .{ .on_list_focus = .{ .context = self, .changed = onTerminalListFocus } };
        self.terminal_focus_subscription = null;
        self.focus_subscriptions = .{ null, null, null, null };
        self.suppress_global_command = false;
        self.git_model = git_model_mod.Model.init(allocator);
        self.scm = SCMContribution.init(allocator);
        self.scm_view_model = null;
        self.scm_container = null;
        self.quit_requested = false;
        self.images = ui.image.Runtime.init(allocator);
        self.pointer = .default;
        self.pointer_state = .{};
        self.pointer_shapes = false;
        self.media_status = null;
        self.focus = .editor;
        self.sidebar = null;
        self.hovered_sash = null;
        self.explorer_container = null;
        self.explorer_view_model = null;
        self.explorer_panes = null;
        self.window_events = .{ .io = self.async_io };
        self.user_keybindings = try user_keybindings_mod.UserKeybindingsLoader.create(allocator, io, self.async_io, &self.window_events);
        errdefer self.user_keybindings.destroy();
        _ = try self.user_keybindings.on_did_change.listen(self, onUserKeybindingsChanged);
        self.search_view = null;
        self.search_service = null;
        try self.initShellModels();
        errdefer self.deinitShellModels();
        self.layout.reset_layout = options.reset_layout;
        self.outline_service = OutlineService.init(allocator);
        errdefer self.outline_service.deinit();
        self.breadcrumbs_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.breadcrumbs_arena.deinit();
        self.navigation_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.navigation_arena.deinit();
        self.pending_references = null;
        self.symbol_picker = null;
        self.pending_symbols = null;
        self.home_path = readHomePath(allocator);
        errdefer if (self.home_path) |path| allocator.free(path);
        self.frame_scheduler = null;
        self.breadcrumb_popup = null;
        self.context_menu_service = .init(allocator, self, reportMenuError);
        errdefer self.context_menu_service.deinit();
        self.hovered_tab = null;
        self.hovered_pane = null;
        self.declarative = null;
        self.json_client = null;
        self.language_features = null;
        self.marker_service = null;
        self.marker_decorations = null;
        self.snippet_provider = SnippetCompletionProvider.init(allocator, io);
        self.snippet_registration = null;
        self.word_completion_provider = null;
        self.word_completion_registration = null;
        self.outline_creator = null;
        self.outline_view = null;
        self.workspace = try WorkspaceContextService.initEmpty(allocator, "workspace");
        errdefer self.workspace.deinit();
        self.configuration = null;
        self.settings_watcher = null;
        self.file_watcher_service = null;
        self.workspace_watcher = null;
        self.contributions = contributions_mod.WorkbenchContributions.init(allocator);
        self.on_will_shutdown = .init(allocator);
        self.on_did_shutdown = .init(allocator);
        self.lifecycle = .init(allocator);
        errdefer self.lifecycle.deinit();
        errdefer self.contributions.deinit();
        try self.contributions.register(.after_restored, self, initAfterRestoredWorkspaceWatcher);
        self.user_settings_paths = &.{};

        self.service = if (state) |previous|
            try editor_groups.EditorGroupsService.initFromSerializedPart(allocator, previous.data, previous.registry, .{})
        else
            try editor_groups.EditorGroupsService.init(allocator, .{});
        errdefer self.service.deinit();
        self.part = try editor_part.EditorPart(GroupPane).initWithState(allocator, self.service, if (state) |previous| previous.data.serialized_grid else null);
        errdefer self.part.deinit();
        self.range_highlights = try RangeHighlightDecorations.create(allocator, @import("codeeditor.zig").Host.forEditorPart(self.part));
        self.part.attachWindow(&self.window_events);
        try self.part.base.register(self.layout.interface());
        self.frame = try ui.Frame.init(allocator, self.cols, self.rows);
        errdefer self.frame.deinit();
        try self.breadcrumbs.init(allocator, self.part, self.workspace, &self.outline_service, self.home_path, .{
            .context = self,
            .file_icon_theme = struct {
                fn run(context: *anyopaque) file_icon.FileIconThemeData {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    return host.getFileIconTheme();
                }
            }.run,
            .open_element = breadcrumbOpenElement,
            .reveal_element = breadcrumbRevealElement,
            .close_popup = struct {
                fn run(context: *anyopaque) void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    if (host.breadcrumb_popup) |popup| popup.close();
                }
            }.run,
            .request_render = requestWorkbenchFrame,
            .focus_editor = breadcrumbFocusEditor,
            .layout_changed = struct {
                fn run(context: *anyopaque) void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    host.layoutAll();
                }
            }.run,
        });
        errdefer self.breadcrumbs.deinit();
        self.editor_drop_target.init(allocator, self.part, &self.window_events, &self.configuration, &self.theme_palette, &self.frame, &self.pointer, .{
            .context = self,
            .terminal_panel_rect = struct {
                fn run(context: *anyopaque) ?ui.Rect {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    return if (host.terminalPanelActive()) host.geometry().panelRect() else null;
                }
            }.run,
            .clear_hover = struct {
                fn run(context: *anyopaque) void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    host.clearTabHover();
                }
            }.run,
            .activate_index = struct {
                fn run(context: *anyopaque, index: usize) !void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    try host.activateIndex(index);
                }
            }.run,
            .copy_editor = struct {
                fn run(context: *anyopaque, pane: *GroupPane, tab: *Tab, open_options: group_mod.EditorOpenOptions) !*Tab {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    return host.copyTabIntoPaneWithOptions(pane, tab, open_options);
                }
            }.run,
            .move_editor = struct {
                fn run(context: *anyopaque, source: *GroupPane, target: *GroupPane, tab: *Tab, open_options: group_mod.EditorOpenOptions) !*Tab {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    return host.moveTabToPaneWithOptions(source, target, tab, open_options);
                }
            }.run,
            .move_terminal_to_panel = struct {
                fn run(context: *anyopaque, pane: *GroupPane, tab: *Tab) !void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    try host.moveTerminalToPanel(pane, tab);
                }
            }.run,
            .destroy_pane = struct {
                fn run(context: *anyopaque, pane: *GroupPane) void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    host.destroyPane(pane);
                }
            }.run,
            .collapse_empty_pane = struct {
                fn run(context: *anyopaque, pane: *GroupPane) void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    host.collapseEmptyPane(pane);
                }
            }.run,
            .focus_pane = struct {
                fn run(context: *anyopaque, pane: *GroupPane) !void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    try host.focusPane(pane);
                }
            }.run,
        });
        errdefer self.editor_drop_target.deinit();
        self.services = .init(allocator);
        std.mem.swap(ServiceCollection, services, &self.services);
        errdefer self.services.deinit();
        try self.initQuickAccess();
        return self;
    }

    pub fn startup(self: *Workbench) !*InstantiationService {
        const window = self.startup_window orelse return error.WorkbenchAlreadyStarted;
        self.startup_window = null;
        try self.initServices();
        try self.instantiation.invokeFunction(startWorkbench, .{ self, window.parent, window.options });
        if (window.has_previous_state) {
            try self.restoreEditors();
            self.layoutAll();
        } else try self.part.when_restored.open(self.allocator);
        return &self.instantiation;
    }

    fn startWorkbench(accessor: ServicesAccessor, self: *Workbench, parent: *ui.Node, options: IWorkbenchOptions) !void {
        try self.layout.initLayout(self.part);
        try self.registerDefaultCommands();
        try @import("../workbench.common.main.zig").registerMenus(&self.commands.menus);
        try self.contributions.start(accessor);
        _ = try self.ensureContextKeys();
        try self.registerListeners();
        try self.renderWorkbench(parent, options);
        try self.createNotificationsHandlers();
        try self.layout.createWorkbenchLayout();
        self.layoutAll();
    }

    fn createNotificationsHandlers(self: *Workbench) !void {
        const notifications = @import("parts/notifications/notificationsCommands.zig");
        const controller = try notifications.NotificationsController.create(self.allocator, self.notification_service, &self.statusbar, &self.window_events, (try self.ensureContextKeys()).interface(), .{
            .context = self,
            .request_frame = notificationFrame,
            .open_link = notificationOpenLink,
            .focus_editor = notificationFocusEditor,
        });
        errdefer controller.deinit();
        try controller.attachConfiguration(self.configuration);
        _ = try self.services.set(notifications.controller_id, controller);
        try notifications.registerNotificationCommands(&self.commands, &self.instantiation);
        self.notification_controller = controller;
    }

    fn notificationFrame(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.requestFrame();
    }
    fn notificationFocusEditor(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.focusEditor();
    }
    fn notificationOpenLink(context: *anyopaque, href: []const u8) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        if (std.mem.startsWith(u8, href, "command:")) {
            try self.commands.execute(href["command:".len..]);
        } else if (std.mem.startsWith(u8, href, "file://")) {
            try self.openPath(href["file://".len..]);
        } else _ = try @import("../../platform/opener/common/opener.zig").openExternal(self.allocator, self.io, href);
    }

    fn registerListeners(self: *Workbench) !void {
        _ = try self.lifecycle_api.on_will_shutdown.listen(self, onWillShutdown);
        _ = try self.lifecycle_api.on_did_shutdown.listen(self, onDidShutdown);
        _ = try self.dialog_api.on_will_show_dialog.listenSignal(self, onDialogStateChanged);
        _ = try self.dialog_api.on_did_show_dialog.listenSignal(self, onDialogStateChanged);
        _ = try self.part.on_did_focus.listen(self, onEditorPartFocus);
        _ = try self.part.on_did_add_group.listenSignal(self, onEditorGroupsChanged);
        _ = try self.part.on_did_move_group.listenSignal(self, onEditorGroupsChanged);
        _ = try self.service.on_did_active_editor_change.listen(self, onActiveMarkdownEditor);
        try self.history.registerListeners(.{
            .context = self,
            .part = self.part,
            .io = self.io,
            .open_path = struct {
                fn run(context: *anyopaque, path: []const u8) !void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    try host.openPath(path);
                }
            }.run,
            .focus_editor = struct {
                fn run(context: *anyopaque) void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    host.focusEditor();
                }
            }.run,
        });
        self.focus_subscriptions[0] = try self.service.on_did_active_editor_change.listenSignal(self, updatePartFocus);
        self.focus_subscriptions[1] = try self.service.on_did_visible_editors_change.listenSignal(self, updatePartFocus);
        self.focus_subscriptions[2] = try self.quick_input_api.on_show.listenSignal(self, updatePartFocus);
        self.focus_subscriptions[3] = try self.quick_input_api.on_hide.listenSignal(self, updatePartFocus);
        _ = try self.layout.on_did_change.listen(self, onGridChanged);
        const editor_service = @import("../services/editor/browser/editorService.zig").EditorService{ .part = self.part };
        if (self.editor_status) |status| try status.bindActiveEditor(editor_service);
        if (self.media_status) |status| try status.bindActiveEditor(editor_service);
    }

    fn onWillShutdown(event: lifecycle_mod.WillShutdownEvent, self: *Workbench) !void {
        try self.on_will_shutdown.fire(event);
    }

    fn onDidShutdown(_: void, self: *Workbench) !void {
        try self.on_did_shutdown.fire({});
    }

    fn initServices(self: *Workbench) !void {
        try self.instantiation.init(self.allocator, &self.services);
        self.lifecycle_api = self.lifecycle.interface();
        self.layout_api = self.layout.interface();
        self.window_views = .{ .workbench = self };
        self.views_api = self.window_views.interface();
        _ = try self.services.set(views_service.views_service_id, &self.views_api);
        self.editor_groups_api = self.part.interface();
        _ = try self.services.set(editor_groups.editor_groups_service_id, &self.editor_groups_api);
        self.code_editors = .{ .part = self.part };
        self.code_editor_api = self.code_editors.interface();
        _ = try self.services.set(code_editor_service.code_editor_service_id, &self.code_editor_api);
        self.editors = .{ .part = self.part };
        self.editor_api = self.editors.interface();
        _ = try self.services.set(@import("../services/editor/common/editorService.zig").editor_service_id, &self.editor_api);
        self.dialog_api = self.dialog_service.interface();
        _ = try self.services.set(dialogs.dialog_service_id, &self.dialog_api);
        self.terminal_action_services = terminal_actions.TerminalActionServices.bind(self);
        _ = try self.services.set(terminal_actions.terminal_action_services_id, &self.terminal_action_services);
        _ = try self.services.set(lifecycle_mod.lifecycle_service_id, &self.lifecycle_api);
        _ = try self.services.set(layout_service_mod.layout_service_id, &self.layout_api);
        _ = try self.services.set(@import("../../platform/notification/common/notification.zig").notification_service_id, &self.notification_api);
        try self.instantiation.invokeFunction(setServicesReady, .{});
    }

    fn setServicesReady(accessor: ServicesAccessor) !void {
        try (try accessor.get(lifecycle_mod.lifecycle_service_id)).setPhase(.Ready);
    }

    fn restoreEditors(self: *Workbench) !void {
        const panes = @import("parts/editor/editorPane.zig").RestoredEditorPanes{
            .view_factory = self.view_factory,
            .io = self.io,
            .width = self.cols,
            .height = @max(self.rows -| 2, 1),
            .images = &self.images,
            .history = &self.history,
            .working_copies = &self.working_copy_service,
        };
        try self.part.restoreEditors(panes);
    }

    pub fn restore(self: *Workbench, timer: *WindowTimer, saved: ?Layout.WorkspaceState) !void {
        if (self.restore_timer != null or self.lifecycle.will_shutdown) return error.WorkbenchAlreadyRestoring;
        _ = try self.lifecycle.on_will_shutdown.listen(self, stopRestoration);
        self.restore_timer = timer;
        const restoring = self.layout.restoreParts(saved, &self.part.when_restored);
        try self.layout.when_ready.wait(self.allocator, .{ .context = self, .run = onLayoutReady });
        try restoring;
    }

    fn stopRestoration(_: lifecycle_mod.WillShutdownEvent, self: *Workbench) !void {
        self.cancelRestoreTimer();
    }

    fn cancelRestoreTimer(self: *Workbench) void {
        if (self.restore_timer) |timer| timer.callback = null;
        self.restore_timer = null;
    }

    fn onLayoutReady(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const callback = lifecycle_mod.Continuation{ .context = self, .run = onLayoutRestored };
        self.restore_timer.?.setTimeout(2000, callback);
        try self.layout.when_restored.wait(self.allocator, callback);
    }

    fn onLayoutRestored(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        if (self.restore_timer == null or self.lifecycle.phase.reached(.Restored)) return;
        defer self.restore_timer.?.setTimeout(2500, .{ .context = self, .run = scheduleEventually });
        try self.lifecycle_api.setPhase(.Restored);
        if (self.notification_controller) |controller| try controller.toasts.start();
    }

    fn scheduleEventually(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.restore_timer.?.runWhenIdle(2500, .{ .context = self, .run = onWindowIdle });
    }

    fn onWindowIdle(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        try self.lifecycle_api.setPhase(.Eventually);
    }

    pub fn createFileSerializer(self: *Workbench) FileEditorSerializer {
        return FileEditorSerializer.init(self.allocator, self.io, self.cols, self.editorContentHeight());
    }

    fn initShellModels(self: *Workbench) !void {
        self.dialog_service = .init(self.allocator);
        errdefer self.dialog_service.deinit();
        self.dialog_handler = try @import("parts/dialogs/dialog.web.contribution.zig").DialogHandlerContribution.create(self.allocator, &self.dialog_service.model);
        errdefer self.dialog_handler.destroy();
        self.problems_view = null;
        self.marker_listener = null;
        self.markers_status = null;
        self.range_highlights = null;
        self.layout = Layout.init(self.allocator);
        self.layout.zen_host = .{
            .context = self,
            .get_configuration = readZenModeConfiguration,
            .get_centered_options = centeredEditorOptions,
            .configured_visible = configuredPartVisible,
            .get_focused_part = focusedLayoutPart,
            .focus_part = focusLayoutPart,
            .apply_line_numbers = applyZenLineNumbers,
        };
        errdefer self.layout.deinit();
        self.activity_bar_part = ActivityBarPart.init(self.allocator);
        errdefer self.activity_bar_part.deinit();
        self.sidebar_part = SidebarPart.init(self.allocator);
        errdefer self.sidebar_part.deinit();
        self.sidebar_part.attachActivityBar(&self.activity_bar_part);
        self.panel_part = PanelPart.init(self.allocator);
        errdefer self.panel_part.deinit();
        self.sidebar_part.base.resize_primary = SidebarPart.resizeWidth;
        self.panel_part.base.resize_primary = PanelPart.resizeHeight;
        const layout_service = self.layout.interface();
        try self.sidebar_part.base.register(layout_service);
        try self.panel_part.base.register(layout_service);
        try self.activity_bar_part.base.register(layout_service);
        self.view_containers_registry = views_mod.ViewContainersRegistry.init(self.allocator);
        errdefer self.view_containers_registry.deinit();
        self.view_descriptor_service = ViewDescriptorService.init(self.allocator, &self.view_containers_registry);
        errdefer self.view_descriptor_service.deinit();
        try self.view_descriptor_service.attach();
        _ = try self.view_descriptor_service.on_did_change_container.listen(self, onViewContainerChanged);
        self.notification_controller = null;
        self.notification_storage = storage_mod.InMemoryStorageService.init(self.allocator);
        errdefer self.notification_storage.deinit();
        self.notification_service = try @import("../services/notification/common/notificationService.zig").NotificationService.create(self.allocator, &self.notification_storage);
        errdefer self.notification_service.deinit();
        self.notification_api = self.notification_service.interface();
        self.layout.notification_service = self.notification_api;
        self.statusbar = try StatusbarService.init(self.allocator);
        errdefer self.statusbar.deinit();
        try self.statusbar.main_part.base.register(layout_service);
        self.activity_service = ActivityService.init(self.allocator);
        errdefer self.activity_service.deinit();

        try self.layout.setSize(.sidebar, 28);

        for (activity_bar_mod.default_activities) |activity| {
            try self.activity_bar_part.addActivity(activity);
        }
        try self.activity_bar_part.setVisible(true);

        try self.registerViewContainers();
        try self.initExplorerContainer();
        try self.sidebar_part.setWidth(28);
        try self.initStatusHint();
    }

    /// Registers the portable view containers at their upstream locations and
    /// fills the side bar and panel composite bars from the registry.
    fn registerViewContainers(self: *Workbench) !void {
        const registry = &self.view_containers_registry;
        // Side-bar ids stay the activity ids the terminal activity bar routes
        // on; Explorer is the default container.
        _ = try registry.register(.{
            .id = "explorer",
            .title = "Explorer",
            .glyph = '\u{f07b}',
            .order = 0,
        }, .sidebar, .{ .is_default = true });
        _ = try registry.register(.{
            .id = "search",
            .title = "Search",
            .glyph = '\u{f002}',
            .order = 1,
        }, .sidebar, .{});
        _ = try registry.register(.{
            .id = "scm",
            .title = "Source Control",
            .glyph = '\u{e702}',
            .order = 2,
        }, .sidebar, .{});
        // Panel containers: Problems order 0, Terminal order 3, matching
        // `markers.contribution.ts` and `terminal.contribution.ts`.
        _ = try registry.register(.{
            .id = PROBLEMS_CONTAINER_ID,
            .title = markers_common.PROBLEMS_TITLE,
            .glyph = '!',
            .hide_if_empty = true,
            .order = 0,
        }, .panel, .{});
        _ = try registry.register(.{
            .id = TERMINAL_CONTAINER_ID,
            .title = "Terminal",
            .glyph = '>',
            .hide_if_empty = true,
            .order = 3,
        }, .panel, .{ .is_default = true, .do_not_register_open_command = true });

        try self.fillPaneComposites(&self.sidebar_part.pane, .sidebar);
        try self.fillPaneComposites(&self.panel_part.pane, .panel);

        const panel_containers = try self.view_descriptor_service.getViewContainersByLocation(.panel, self.allocator);
        defer self.allocator.free(panel_containers);
        for (panel_containers) |container| {
            if (container.hide_if_empty) {
                _ = try self.panel_part.pane.setPaneCompositeVisible(container.id, false);
            }
        }
    }

    /// Port of the Explorer viewlet's two stacked views. Upstream registers
    /// Explorer and Outline in the Explorer view container; the terminal
    /// `ViewPaneContainer` renders their section headers and splits the body.
    fn initExplorerContainer(self: *Workbench) !void {
        const model = try self.allocator.create(view_container_model_mod.ViewContainerModel);
        errdefer self.allocator.destroy(model);
        model.* = view_container_model_mod.ViewContainerModel.init(self.allocator, .{
            .id = "explorer",
            .title = "Explorer",
            .icon = "E",
        });
        errdefer model.deinit();
        try addSidebarViewDescriptors(model, false, false);
        model.setActiveView("explorer");

        const panes = try self.allocator.alloc(view_pane_container_mod.Pane, 4);
        errdefer self.allocator.free(panes);
        panes[0] = .{
            .id = "explorer",
            .title = "Explorer",
            .context = self,
            .render_body = explorerPaneRenderBody,
            .handle_key = explorerPaneHandleKey,
            .handle_mouse = explorerPaneHandleMouse,
            .title_actions = explorerPaneTitleActions,
        };
        panes[1] = .{
            .id = "outline",
            .title = "Outline",
            .context = self,
            .render_body = outlinePaneRenderBody,
            .handle_key = outlinePaneHandleKey,
            .handle_mouse = outlinePaneHandleMouse,
            .title_actions = outlinePaneTitleActions,
        };
        panes[2] = .{
            .id = "changes",
            .title = "Changes",
            .context = self,
            .render_body = scmChangesRenderBody,
            .handle_key = scmChangesHandleKey,
            .handle_mouse = scmChangesHandleMouse,
            .title_actions = scmChangesTitleActions,
        };
        panes[3] = .{
            .id = "graph",
            .title = "Graph",
            .context = self,
            .render_body = scmHistoryRenderBody,
            .handle_key = scmHistoryHandleKey,
            .handle_mouse = scmHistoryHandleMouse,
            .title_actions = scmHistoryTitleActions,
            .show_actions = .when_expanded,
        };
        for (panes) |*pane| pane.run_title_action = runPaneTitleAction;
        const container = try self.createSidebarContainer(model, panes);
        self.explorer_panes = panes;
        self.explorer_view_model = model;
        self.explorer_container = container;
    }

    fn createSidebarContainer(self: *Workbench, model: *view_container_model_mod.ViewContainerModel, panes: []const view_pane_container_mod.Pane) !*view_pane_container_mod.ViewPaneContainer {
        try self.view_descriptor_service.registerViewContainerModel(model);
        errdefer self.view_descriptor_service.unregisterViewContainerModel(model);
        const container = try view_pane_container_mod.ViewPaneContainer.init(self.allocator, model, panes);
        errdefer {
            container.deinit();
            self.allocator.destroy(container);
        }
        try self.sidebar_part.registerViewPaneContainer(container);
        return container;
    }

    fn addSidebarViewDescriptors(model: *view_container_model_mod.ViewContainerModel, has_scm: bool, has_history: bool) !void {
        const scm = std.mem.eql(u8, model.container.id, "scm");
        try model.addView(.{ .id = "explorer", .name = "Explorer", .order = 0, .weight = 70, .in_container = !scm, .can_toggle_visibility = false });
        try model.addView(.{ .id = "outline", .name = "Outline", .order = 1, .weight = 30, .in_container = !scm, .collapsed = true });
        try model.addView(.{ .id = "changes", .name = "Changes", .order = 1, .weight = 40, .in_container = scm, .available = has_scm });
        try model.addView(.{ .id = "graph", .name = "Graph", .order = 2, .weight = 40, .in_container = scm, .available = has_history });
    }

    fn fillPaneComposites(self: *Workbench, part: *pane_composite_mod.PaneCompositePart, location: views_mod.ViewContainerLocation) !void {
        const containers = try self.view_descriptor_service.getViewContainersByLocation(location, self.allocator);
        defer self.allocator.free(containers);
        views_mod.sortByOrder(containers);
        for (containers) |container| {
            try part.addPaneComposite(.{
                .id = container.id,
                .name = container.title,
                .order = container.order,
                .glyph = container.glyph,
            });
        }
    }

    fn initStatusHint(self: *Workbench) !void {
        // VS Code's status bar has no quit hint. The entry is kept for the
        // Source Control messages set through `status_hint_accessor`, but it
        // starts empty: the status bar and focus navigation skip empty
        // entries, so it only appears once a message replaces the text.
        self.status_hint_accessor = try self.statusbar.addEntry(.{
            .name = "Source Control",
            .text = "",
        }, "workbench.hint", .right, .{ .number = 0 });
        self.markers_status = try MarkersStatusBar.init(self.allocator, &self.statusbar);
    }

    fn deinitShellModels(self: *Workbench) void {
        self.dialog_handler.destroy();
        self.dialog_service.deinit();
        if (self.problems_view) |*view| {
            view.deinit();
            self.problems_view = null;
        }
        if (self.range_highlights) |highlights| {
            highlights.destroy();
            self.range_highlights = null;
        }
        if (self.markers_status) |status| {
            status.deinit();
            self.markers_status = null;
        }
        if (self.explorer_container) |container| {
            self.sidebar_part.unregisterViewPaneContainer(container);
            self.view_descriptor_service.unregisterViewContainerModel(container.model);
            container.deinit();
            self.allocator.destroy(container);
            self.explorer_container = null;
        }
        if (self.explorer_view_model) |model| {
            model.deinit();
            self.allocator.destroy(model);
            self.explorer_view_model = null;
        }
        if (self.explorer_panes) |panes| {
            self.allocator.free(panes);
            self.explorer_panes = null;
        }
        if (self.search_view) |view| view.detachActivity();
        self.activity_service.deinit();
        if (self.notification_controller) |controller| controller.deinit();
        self.statusbar.deinit();
        self.notification_service.deinit();
        self.notification_storage.deinit();
        self.panel_part.deinit();
        self.sidebar_part.deinit();
        self.view_descriptor_service.deinit();
        self.view_containers_registry.deinit();
        self.activity_bar_part.deinit();
        self.layout.deinit();
    }

    fn initQuickAccess(self: *Workbench) !void {
        self.view_state_storage = null;
        self.sidebar_action_anchor = null;
        self.history = HistoryService.init(self.allocator);
        errdefer self.history.deinit();

        self.commands = CommandRegistry.init(self.allocator);
        self.working_copy_service = WorkingCopyService.init(self.allocator);
        errdefer self.working_copy_service.deinit();
        errdefer self.commands.deinit();
        self.menu_service = .initWithKeybindings(self.allocator, &self.commands.menus, &self.commands.platform, &self.commands.bindings);
        errdefer self.menu_service.deinit();
        self.commands.setEditorAvailability(self, hasActiveEditor);

        self.quick_access = try QuickAccessService.init(
            self.allocator,
            self.io,
            self.workspace,
            &self.history,
            &self.commands,
            .{
                .context = self,
                .window = &self.window_events,
                .open_file = quickOpenFile,
                .open_file_to_side = quickOpenToSide,
                .configure_keybinding = quickConfigureBinding,
                .lookup_keycaps = quickLookupKeycaps,
                .report_error = quickReportError,
                .cancel_popups = quickCancelPopups,
                .get_excludes = quickGetExcludes,
                .get_file_search_settings = quickGetFileSearchSettings,
            },
        );
        errdefer self.quick_access.deinit();
        self.quick_input_api = self.quick_access.interface();
        _ = try self.services.set(@import("../../platform/quickinput/common/quickInput.zig").quick_input_service_id, &self.quick_input_api);

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
        self.media_status = try MediaPreviewStatus.init(self.allocator, &self.statusbar);
        errdefer {
            if (self.media_status) |status| status.deinit();
            self.media_status = null;
        }

        self.simple_browser = .{ .allocator = self.allocator, .io = self.io, .quick_input = self.quick_access.inputService(), .context = self, .open_editor = openTerminalEditorWithProfile, .report_error = reportEditorMessage };
        self.builtin_host = try @import("../api/browser/builtinExtensionHost.zig").BuiltinExtensionHost.init(self.allocator, self.builtinExtensionServices());
        self.statusbar.setCommandExecutor(.{
            .context = self,
            .execute = executeStatusbarCommand,
        });
    }

    pub fn builtinExtensionServices(self: *Workbench) @import("../api/browser/builtinExtensionHost.zig").Services {
        const Host = struct {
            fn get(context: *anyopaque) *Workbench {
                return @ptrCast(@alignCast(context));
            }
            fn languageFeatures(context: *anyopaque) ?*LanguageFeaturesService {
                return get(context).language_features;
            }
            fn configuration(context: *anyopaque) ?*ConfigurationService {
                return get(context).configuration;
            }
            fn launchTerminal(context: *anyopaque, name: []const u8, executable: []const u8, args: []const []const u8, cwd: ?[]const u8) !*terminal_service_mod.TerminalInstance {
                return get(context).launchTerminalProcess(name, executable, args, cwd);
            }
            fn terminalInstance(context: *anyopaque, id: usize) ?*terminal_service_mod.TerminalInstance {
                const service = get(context).terminal_service orelse return null;
                return service.getInstanceFromId(id);
            }
            fn updateConfiguration(context: *anyopaque, key: []const u8, value: ?std.json.Value) !void {
                try get(context).setUserConfigurationValue(key, value);
            }
            fn statusHint(context: *anyopaque, message: []const u8) void {
                get(context).setStatusHint("{s}", .{message});
            }
            fn closeActive(context: *anyopaque) !void {
                try get(context).forceCloseActive();
            }
            fn openPath(context: *anyopaque, path: []const u8) !void {
                try get(context).openPath(path);
            }
            fn switchTab(context: *anyopaque, delta: isize) !void {
                try get(context).switchTab(delta);
            }
            fn historyBack(context: *anyopaque) !bool {
                return get(context).goBackInHistory();
            }
            fn historyForward(context: *anyopaque) !bool {
                return get(context).goForwardInHistory();
            }
            fn recordNavigation(context: *anyopaque) void {
                get(context).recordNavigationWithReason(.NAVIGATION);
            }
        };
        return .{
            .context = self,
            .io = self.io,
            .editors = .{ .part = self.part },
            .commands = &self.commands,
            .statusbar = &self.statusbar,
            .quick_input = self.quick_access.inputService(),
            .language_features = Host.languageFeatures,
            .configuration = Host.configuration,
            .launch_terminal = Host.launchTerminal,
            .terminal_instance = Host.terminalInstance,
            .update_configuration = Host.updateConfiguration,
            .status_hint = Host.statusHint,
            .force_close_active = Host.closeActive,
            .open_path = Host.openPath,
            .switch_tab = Host.switchTab,
            .history_back = Host.historyBack,
            .history_forward = Host.historyForward,
            .record_navigation = Host.recordNavigation,
        };
    }

    fn registerDefaultCommands(self: *Workbench) !void {
        const status = self.editor_status.?;
        try self.commands.register(.{ .id = "workbench.action.quickOpen", .label = "Go to File...", .category = "File", .context = self, .run = commandQuickOpen });
        try self.commands.registerAction(&self.instantiation, @import("../contrib/quickaccess/browser/commandsQuickAccess.zig").ShowAllCommandsAction.descriptor);
        const before_group_focus = [_]commands_mod.CommandInfo{
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
            .{ .id = "github.publish", .label = "Publish to GitHub", .category = "GitHub", .context = self, .run = commandGithubPublish },
            .{ .id = "simpleBrowser.show", .label = "Show", .category = "Simple Browser", .context = &self.simple_browser, .run = SimpleBrowserManager.run },
            .{ .id = "workbench.action.browser.open", .label = "Open Integrated Browser", .show_in_palette = false, .context = &self.simple_browser, .run = SimpleBrowserManager.run },
            .{ .id = "workbench.action.openSettingsJson", .label = "Open User Settings (JSON)", .category = "Preferences", .context = self, .run = commandOpenSettingsJson },
            .{ .id = "workbench.action.openGlobalKeybindingsFile", .label = "Open Keyboard Shortcuts (JSON)", .category = "Preferences", .context = self, .run = commandOpenKeybindingsJson },
            .{ .id = "workbench.action.closeActiveEditor", .label = "Close Editor", .category = "View", .context = self, .run = commandCloseEditor },
            .{ .id = "workbench.action.reopenClosedEditor", .label = "Reopen Closed Editor", .category = "View", .context = self, .run = commandReopenClosedEditor },
            .{ .id = "breadcrumbs.focusAndSelect", .label = "Focus and Select Breadcrumbs", .category = "View", .context = self, .run = commandFocusAndSelectBreadcrumbs },
            .{ .id = "breadcrumbs.focus", .label = "Focus Breadcrumbs", .category = "View", .context = self, .run = commandFocusBreadcrumbs },
            .{ .id = "outline.focus", .label = "Focus Outline", .category = "View", .context = self, .run = commandFocusOutline },
            .{ .id = OutlinePane.more_actions_id, .label = "Outline More Actions", .show_in_palette = false, .context = self, .run = commandOutlineMoreActions },
            .{ .id = "outline.collapse", .label = "Collapse All", .category = "View", .context = self, .run = commandOutlineCollapse },
            .{ .id = "outline.expand", .label = "Expand All", .category = "View", .context = self, .run = commandOutlineExpand },
            .{ .id = "outline.followCursor", .label = "Follow Cursor", .category = "View", .context = self, .run = commandOutlineFollowCursor },
            .{ .id = "outline.filterOnType", .label = "Filter on Type", .category = "View", .context = self, .run = commandOutlineFilterOnType },
            .{ .id = "outline.sortByPosition", .label = "Sort By: Position", .category = "View", .context = self, .run = commandOutlineSortByPosition },
            .{ .id = "outline.sortByName", .label = "Sort By: Name", .category = "View", .context = self, .run = commandOutlineSortByName },
            .{ .id = "outline.sortByKind", .label = "Sort By: Category", .category = "View", .context = self, .run = commandOutlineSortByKind },
            .{ .id = "workbench.action.splitEditor", .label = "Split Editor", .category = "View", .context = self, .run = commandSplitEditor },
            .{ .id = "workbench.action.splitEditorOrthogonal", .label = "Split Editor Orthogonal", .category = "View", .context = self, .run = commandSplitEditorOrthogonal },
            .{ .id = "workbench.action.splitEditorLeft", .label = "Split Editor Left", .category = "View", .context = self, .run = commandSplitEditorLeft },
            .{ .id = "workbench.action.splitEditorRight", .label = "Split Editor Right", .category = "View", .context = self, .run = commandSplitEditorRight },
            .{ .id = "workbench.action.splitEditorUp", .label = "Split Editor Up", .category = "View", .context = self, .run = commandSplitEditorUp },
            .{ .id = "workbench.action.splitEditorDown", .label = "Split Editor Down", .category = "View", .context = self, .run = commandSplitEditorDown },
        };
        for (before_group_focus) |command| try self.commands.register(command);
        for (@import("parts/editor/editorActions.zig").focus_group_actions) |action| try self.commands.registerAction(&self.instantiation, action);
        const editor_actions = @import("parts/editor/editorActions.zig");
        for (editor_actions.new_group_actions) |action| try self.commands.registerAction(&self.instantiation, action);
        const editor_commands = [_]commands_mod.CommandInfo{
            .{ .id = "workbench.action.closeGroup", .label = "Close Editor Group", .category = "View", .context = self, .run = commandCloseGroup },
            .{ .id = "workbench.action.joinTwoGroups", .label = "Join Editor Group with Next Group", .category = "View", .context = self, .run = commandJoinTwoGroups },
        };
        for (editor_commands) |command| try self.commands.register(command);
        for (editor_actions.move_group_actions) |action| try self.commands.registerAction(&self.instantiation, action);
        const after_move_groups = [_]commands_mod.CommandInfo{
            .{ .id = "workbench.action.duplicateActiveEditorGroupLeft", .label = "Duplicate Editor Group Left", .category = "View", .context = self, .run = commandDuplicateGroupLeft },
            .{ .id = "workbench.action.duplicateActiveEditorGroupRight", .label = "Duplicate Editor Group Right", .category = "View", .context = self, .run = commandDuplicateGroupRight },
            .{ .id = "workbench.action.duplicateActiveEditorGroupUp", .label = "Duplicate Editor Group Up", .category = "View", .context = self, .run = commandDuplicateGroupUp },
            .{ .id = "workbench.action.duplicateActiveEditorGroupDown", .label = "Duplicate Editor Group Down", .category = "View", .context = self, .run = commandDuplicateGroupDown },
            .{ .id = "workbench.action.moveEditorToPreviousGroup", .label = "Move Editor into Previous Group", .category = "View", .context = self, .run = commandMoveEditorToPreviousGroup },
            .{ .id = "workbench.action.moveEditorToNextGroup", .label = "Move Editor into Next Group", .category = "View", .context = self, .run = commandMoveEditorToNextGroup },
            .{ .id = "workbench.action.moveEditorToAboveGroup", .label = "Move Editor into Group Above", .category = "View", .context = self, .run = commandMoveEditorToAboveGroup },
            .{ .id = "workbench.action.moveEditorToBelowGroup", .label = "Move Editor into Group Below", .category = "View", .context = self, .run = commandMoveEditorToBelowGroup },
            .{ .id = "workbench.action.moveEditorToLeftGroup", .label = "Move Editor into Left Group", .category = "View", .context = self, .run = commandMoveEditorToLeftGroup },
            .{ .id = "workbench.action.moveEditorToRightGroup", .label = "Move Editor into Right Group", .category = "View", .context = self, .run = commandMoveEditorToRightGroup },
            .{ .id = "workbench.action.moveEditorToFirstGroup", .label = "Move Editor into First Group", .category = "View", .context = self, .run = commandMoveEditorToFirstGroup },
            .{ .id = "workbench.action.moveEditorToLastGroup", .label = "Move Editor into Last Group", .category = "View", .context = self, .run = commandMoveEditorToLastGroup },
            .{ .id = "workbench.action.splitEditorToPreviousGroup", .label = "Split Editor into Previous Group", .category = "View", .context = self, .run = commandSplitEditorToPreviousGroup },
            .{ .id = "workbench.action.splitEditorToNextGroup", .label = "Split Editor into Next Group", .category = "View", .context = self, .run = commandSplitEditorToNextGroup },
            .{ .id = "workbench.action.splitEditorToAboveGroup", .label = "Split Editor into Group Above", .category = "View", .context = self, .run = commandSplitEditorToAboveGroup },
            .{ .id = "workbench.action.splitEditorToBelowGroup", .label = "Split Editor into Group Below", .category = "View", .context = self, .run = commandSplitEditorToBelowGroup },
            .{ .id = "workbench.action.splitEditorToLeftGroup", .label = "Split Editor into Left Group", .category = "View", .context = self, .run = commandSplitEditorToLeftGroup },
            .{ .id = "workbench.action.splitEditorToRightGroup", .label = "Split Editor into Right Group", .category = "View", .context = self, .run = commandSplitEditorToRightGroup },
            .{ .id = "workbench.action.splitEditorToFirstGroup", .label = "Split Editor into First Group", .category = "View", .context = self, .run = commandSplitEditorToFirstGroup },
            .{ .id = "workbench.action.splitEditorToLastGroup", .label = "Split Editor into Last Group", .category = "View", .context = self, .run = commandSplitEditorToLastGroup },
            .{ .id = "workbench.action.navigateLeft", .label = "Focus Group Left", .category = "View", .context = self, .run = commandNavigateLeft },
            .{ .id = "workbench.action.navigateRight", .label = "Focus Group Right", .category = "View", .context = self, .run = commandNavigateRight },
            .{ .id = "workbench.action.navigateUp", .label = "Focus Group Up", .category = "View", .context = self, .run = commandNavigateUp },
            .{ .id = "workbench.action.navigateDown", .label = "Focus Group Down", .category = "View", .context = self, .run = commandNavigateDown },
        };
        for (after_move_groups) |command| try self.commands.register(command);
        try self.commands.registerAction(&self.instantiation, editor_actions.navigate_between_groups_action);
        try self.commands.registerAction(&self.instantiation, editor_actions.reset_group_sizes_action);
        const after_group_actions = [_]commands_mod.CommandInfo{
            .{ .id = "workbench.action.increaseViewWidth", .label = "Increase Editor Width", .category = "View", .context = self, .run = commandIncreaseViewWidth },
            .{ .id = "workbench.action.decreaseViewWidth", .label = "Decrease Editor Width", .category = "View", .context = self, .run = commandDecreaseViewWidth },
            .{ .id = "workbench.action.increaseViewHeight", .label = "Increase Editor Height", .category = "View", .context = self, .run = commandIncreaseViewHeight },
            .{ .id = "workbench.action.decreaseViewHeight", .label = "Decrease Editor Height", .category = "View", .context = self, .run = commandDecreaseViewHeight },
            .{ .id = "workbench.action.maximizeEditor", .label = "Maximize Editor Group", .category = "View", .context = self, .run = commandMaximizeEditor },
            .{ .id = "workbench.action.closePanel", .label = "Close Panel", .category = "View", .context = self, .run = commandClosePanel },
            .{ .id = "workbench.action.closeAllEditors", .label = "Close All Editors", .category = "View", .context = self, .run = commandCloseAllEditors },
            .{ .id = "workbench.action.closeOtherEditors", .label = "Close Other Editors", .category = "View", .context = self, .run = commandCloseOtherEditors },
            .{ .id = "workbench.action.joinAllGroups", .label = "Join All Editor Groups", .category = "View", .context = self, .run = commandJoinAllGroups },
            .{ .id = "workbench.action.lastEditorInGroup", .label = "Last Editor in Group", .category = "View", .context = self, .run = commandLastEditorInGroup },
            .{ .id = "workbench.action.previousEditor", .label = "Previous Editor", .category = "View", .context = self, .run = commandPreviousEditor },
            .{ .id = "workbench.action.openEditorAtIndex1", .label = "Open Editor 1", .category = "View", .context = self, .run = commandOpenEditorAtIndex1 },
            .{ .id = "workbench.action.revertAndCloseActiveEditor", .label = "Revert and Close Editor", .category = "View", .context = self, .run = commandRevertAndCloseActiveEditor },
        };
        for (after_group_actions) |command| try self.commands.register(command);
        try self.commands.registerAction(&self.instantiation, terminal_actions.editor_action);
        const after_terminal_editor = [_]commands_mod.CommandInfo{
            .{ .id = "workbench.view.explorer", .label = "View: Show Explorer", .category = "View", .context = self, .run = commandViewExplorer },
            .{ .id = "workbench.view.scm", .label = "View: Show Source Control", .category = "View", .context = self, .run = commandViewScm },
            .{ .id = markers_common.Markers.SHOW_MARKERS_VIEW_ACTION_ID, .label = "View: Show Problems", .category = "View", .context = self, .run = commandShowProblems },
            .{ .id = markers_common.Markers.TOGGLE_MARKERS_VIEW_ACTION_ID, .label = "View: Toggle Problems", .category = "View", .context = self, .run = commandToggleProblems },
            .{ .id = "workbench.action.togglePanel", .label = "View: Toggle Panel Visibility", .category = "View", .context = self, .run = commandTogglePanel },
        };
        for (after_terminal_editor) |command| try self.commands.register(command);
        try self.commands.registerAction(&self.instantiation, zen_mode_contribution.toggle_action);
        try self.commands.registerAction(&self.instantiation, zen_mode_contribution.exit_action);
        try self.commands.registerAction(&self.instantiation, @import("actions/layoutActions.zig").toggle_centered_layout_action);
        const before_scm = [_]commands_mod.CommandInfo{
            .{
                .id = zen_mode_contribution.zen_hide_editor_tabs_id,
                .label = zen_mode_contribution.zen_hide_editor_tabs_label,
                .category = zen_mode_contribution.category,
                .description = zen_mode_contribution.zen_hide_editor_tabs_description,
                .precondition = zenTabsHideAvailable,
                .context = self,
                .run = commandZenHideEditorTabs,
            },
            .{
                .id = zen_mode_contribution.zen_show_multiple_editor_tabs_id,
                .label = zen_mode_contribution.zen_show_multiple_editor_tabs_label,
                .category = zen_mode_contribution.category,
                .description = zen_mode_contribution.zen_show_multiple_editor_tabs_description,
                .precondition = zenTabsMultipleAvailable,
                .context = self,
                .run = commandZenShowMultipleEditorTabs,
            },
            .{
                .id = zen_mode_contribution.zen_show_single_editor_tab_id,
                .label = zen_mode_contribution.zen_show_single_editor_tab_label,
                .category = zen_mode_contribution.category,
                .description = zen_mode_contribution.zen_show_single_editor_tab_description,
                .precondition = zenTabsSingleAvailable,
                .context = self,
                .run = commandZenShowSingleEditorTab,
            },
            .{ .id = "workbench.action.focusPanel", .label = "View: Focus Panel", .category = "View", .context = self, .run = commandFocusPanel },
            .{ .id = "workbench.action.previousPanelView", .label = "View: Previous Panel View", .category = "View", .context = self, .run = commandPreviousPanelView },
            .{ .id = "workbench.action.nextPanelView", .label = "View: Next Panel View", .category = "View", .context = self, .run = commandNextPanelView },
            .{ .id = "git.refresh", .label = "Refresh", .category = "Source Control", .context = self, .run = commandGitRefresh },
            .{ .id = "git.commit", .label = "Commit", .category = "Source Control", .context = self, .run = commandGitCommit },
            .{ .id = scm_view_mod.CHANGES_MENU_ACTION_ID, .label = "Changes More Actions", .show_in_palette = false, .context = self, .run = commandScmChangesMenu },
            .{ .id = scm_history_view_mod.GRAPH_MENU_ACTION_ID, .label = "Graph More Actions", .show_in_palette = false, .context = self, .run = commandScmGraphMenu },
            .{ .id = "workbench.scm.action.showMenu", .label = "Source Control More Actions", .show_in_palette = false, .context = self, .run = commandScmMenu },
            .{ .id = "git.fetchAll", .label = "Fetch From All Remotes", .category = "Source Control", .context = self, .run = commandGitFetch },
            .{ .id = "git.pullRef", .label = "Pull", .category = "Source Control", .context = self, .run = commandGitPull },
            .{ .id = "git.pushRef", .label = "Push", .category = "Source Control", .context = self, .run = commandGitPush },
            .{ .id = "git.publish", .label = "Publish Branch", .category = "Source Control", .context = self, .run = commandGitPublish },
        };
        for (before_scm) |command| try self.commands.register(command);
        for (scm_contribution.view_actions) |action| try self.commands.registerAction(&self.instantiation, action);
        const before_search = [_]commands_mod.CommandInfo{
            .{ .id = "git.openChange", .label = "Open Change", .category = "Source Control", .context = self, .run = commandGitOpenChange },
            .{ .id = "git.openFile", .label = "Open File", .category = "Source Control", .context = self, .run = commandGitOpenFile },
            .{ .id = "workbench.action.compareEditor.nextChange", .label = "Go to Next Change", .category = "Diff", .context = self, .run = commandDiffNext },
            .{ .id = "workbench.action.compareEditor.previousChange", .label = "Go to Previous Change", .category = "Diff", .context = self, .run = commandDiffPrevious },
            .{ .id = "workbench.action.compareEditor.swapSides", .label = "Swap Sides", .category = "Diff", .context = self, .run = commandDiffSwap },
            .{ .id = "workbench.action.compareEditor.refreshDiff", .label = "Refresh Diff", .category = "Diff", .context = self, .run = commandDiffRefresh },
            .{ .id = "workbench.action.toggleSidebarVisibility", .label = "Toggle Primary Side Bar Visibility", .category = "View", .context = self, .run = commandToggleSidebar },
            .{ .id = "workbench.action.closeSidebar", .label = "Close Primary Side Bar", .category = "View", .context = self, .run = commandCloseSidebar },
            .{ .id = "workbench.action.focusSideBar", .label = "Focus into Primary Side Bar", .category = "View", .context = self, .run = commandFocusSidebar },
            .{ .id = "workbench.action.previousSideBarView", .label = "Previous Primary Side Bar View", .category = "View", .context = self, .run = commandPreviousSidebarView },
            .{ .id = "workbench.action.nextSideBarView", .label = "Next Primary Side Bar View", .category = "View", .context = self, .run = commandNextSidebarView },
        };
        for (before_search) |command| try self.commands.register(command);
        try self.commands.registerAction(&self.instantiation, @import("parts/statusbar/statusbarActions.zig").focus_statusbar_action);
        for (terminal_actions.terminal_actions) |action| try self.commands.registerAction(&self.instantiation, action);
        const markdown_commands = [_]commands_mod.CommandInfo{
            .{ .id = "markdown.showSource", .label = "Show Source", .category = "Markdown", .requires_editor = true, .context = self, .run = commandShowMarkdownSource },
            .{ .id = "markdown.showPreview", .label = "Open Preview", .category = "Markdown", .requires_editor = true, .context = self, .run = commandOpenMarkdownPreview },
            .{ .id = "markdown.showPreviewToSide", .label = "Open Preview to the Side", .category = "Markdown", .requires_editor = true, .context = self, .run = commandShowMarkdownPreview },
            .{ .id = "markdown.togglePreview", .label = "Toggle Preview", .category = "Markdown", .requires_editor = true, .context = self, .run = commandToggleMarkdownPreview },
            .{ .id = "markdown.preview.refresh", .label = "Refresh Preview", .category = "Markdown", .requires_editor = true, .context = self, .run = commandRefreshMarkdownPreview },
        };
        for (markdown_commands) |command| try self.commands.register(command);
        for (media_actions.zoom_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        try self.commands.register(.{ .id = media_actions.open_in_text_id, .label = media_actions.open_in_text_title, .category = media_actions.category, .requires_editor = true, .context = self, .run = commandImageOpenInTextEditor });
        const search_contribution = @import("../contrib/search/browser/search.contribution.zig");
        for (search_contribution.search_actions) |action| try self.commands.registerAction(&self.instantiation, action);
        const search_editor_commands = [_]commands_mod.CommandInfo{
            .{ .id = "search.action.openNewEditor", .label = "Open New Search Editor", .category = "Search", .context = self, .run = commandOpenNewSearchEditor },
            .{ .id = "rerunSearchEditorSearch", .label = "Search Again", .category = "Search Editor", .context = self, .run = commandRerunSearchEditor },
        };
        for (search_editor_commands) |command| try self.commands.register(command);
        for (search_contribution.result_actions) |action| try self.commands.registerAction(&self.instantiation, action);
        const editor_commands_1 = [_]commands_mod.CommandInfo{
            .{ .id = "actions.find", .label = "Find", .context = self, .requires_editor = true, .run = commandFind },
            .{ .id = "editor.action.startFindReplaceAction", .label = "Replace", .context = self, .requires_editor = true, .run = commandReplace },
        };
        for (editor_commands_1) |command| try self.commands.register(command);
        for (@import("../../editor/contrib/comment/browser/comment.zig").editor_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        for (@import("../../editor/contrib/linesOperations/browser/linesOperations.zig").editor_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        for (@import("../../editor/contrib/linesOperations/browser/linesOperations.zig").indent_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        for (@import("../../editor/contrib/insertFinalNewLine/browser/insertFinalNewLine.zig").editor_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        for (@import("../../editor/contrib/lineSelection/browser/lineSelection.zig").editor_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        for (@import("../../editor/contrib/multicursor/browser/multicursor.zig").editor_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        for (@import("../../editor/contrib/bracketMatching/browser/bracketMatching.zig").editor_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        for (@import("../../editor/contrib/smartSelect/browser/smartSelect.zig").editor_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        for (@import("../../editor/contrib/format/browser/formatActions.zig").editor_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        for (@import("../../editor/contrib/indentation/browser/indentation.zig").conversion_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        const editor_commands_2 = [_]commands_mod.CommandInfo{
            .{ .id = "editor.action.wordHighlight.trigger", .label = "Trigger Symbol Highlight", .category = "Go", .context = self, .requires_editor = true, .run = commandWordHighlightTrigger },
        };
        for (editor_commands_2) |command| try self.commands.register(command);
        for (@import("../../editor/contrib/inPlaceReplace/browser/inPlaceReplace.zig").editor_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        for (@import("../../editor/contrib/indentation/browser/indentation.zig").reindent_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        for (@import("../../editor/contrib/folding/browser/folding.zig").editor_actions) |action| try self.commands.registerEditorAction(&self.instantiation, action);
        const editor_commands_3 = [_]commands_mod.CommandInfo{
            .{ .id = sticky_actions.toggle_sticky_scroll.id, .label = sticky_actions.toggle_sticky_scroll.label, .category = "View", .context = self, .requires_editor = true, .run = commandToggleStickyScroll },
            .{ .id = sticky_actions.focus_sticky_scroll.id, .label = sticky_actions.focus_sticky_scroll.label, .category = "View", .context = self, .requires_editor = true, .run = commandFocusStickyScroll },
            .{ .id = "editor.action.wordHighlight.next", .label = "Go to Next Symbol Highlight", .category = "Go", .context = self, .requires_editor = true, .run = commandWordHighlightNext },
            .{ .id = "editor.action.wordHighlight.prev", .label = "Go to Previous Symbol Highlight", .category = "Go", .context = self, .requires_editor = true, .run = commandWordHighlightPrevious },
        };
        for (editor_commands_3) |command| try self.commands.register(command);

        try self.builtin_host.registerPortActions();
        try self.references_view.init(&self.builtin_host.context, self.quick_access.inputService());
        self.references_view_registered = true;
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

    fn newContextMenu(self: *Workbench, comptime handler: fn (*Workbench, *MenuActionContext, []const u8) anyerror!void) !*Menu {
        return Menu.init(self.allocator, MenuActionContext{ .workbench = self }, struct {
            fn run(action: *MenuActionContext, id: []const u8) !void {
                try handler(action.workbench, action, id);
            }
        }.run);
    }

    fn reportMenuError(context: *anyopaque, err: anyerror) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        if (self.activeTab()) |tab| tab.editor.setMessage("Menu action failed: {s}", .{@errorName(err)});
    }

    fn showContextMenu(self: *Workbench, menu: *Menu, anchor: MenuAnchor) !void {
        var theme = ui.ContextMenuTheme{};
        if (self.theme_palette) |palette| {
            theme.background = palette.colorOr("menu.background", theme.background);
            theme.foreground = palette.colorOr("menu.foreground", theme.foreground);
            theme.border = palette.colorOr("menu.border", theme.border);
            theme.separator = palette.colorOr("menu.separatorBackground", theme.separator);
            theme.selection_background = palette.colorOr("menu.selectionBackground", theme.selection_background);
            theme.selection_foreground = palette.colorOr("menu.selectionForeground", theme.selection_foreground);
            theme.disabled = palette.colorOr("disabledForeground", theme.disabled);
        }
        try self.context_menu_service.showContextMenu(menu, anchor, theme);
    }

    pub fn isDialogOpen(self: *const Workbench) bool {
        return self.dialog_service.hasDialog();
    }

    /// True once the quit confirmation saved or discarded every dirty tab and
    /// the host should leave the event loop.
    pub fn shouldQuit(self: *const Workbench) bool {
        return self.quit_requested;
    }

    pub fn isQuickAccessOpen(self: *const Workbench) bool {
        return self.quick_access.isOpen();
    }

    pub fn findInFiles(self: *Workbench) !void {
        const search = @import("../contrib/search/browser/searchActionsBase.zig");
        if (try search.openSearchView(self.views_api, true)) |view| try search.findInFiles(view);
    }

    pub fn replaceInFiles(self: *Workbench) !void {
        const search = @import("../contrib/search/browser/searchActionsBase.zig");
        if (try search.openSearchView(self.views_api, true)) |view| search.replaceInFiles(view);
    }

    /// Enables the threaded TextMate background tokenizer. The TUI calls
    /// this after construction; tests leave it off so they keep the
    /// synchronous default background tokenizer.
    pub fn enableAsyncTokenization(self: *Workbench) void {
        if (self.textmate_background != null) return;
        const factory = textmate_background_mod.Factory.init(self.allocator) catch return;
        factory.attachWindow(&self.window_events);
        self.textmate_background = factory;
        TokenizationRegistry.instance.setBackgroundTokenizerFactory(factory.interface());

        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                tab.editor.model.tokenization().resetTokenization();
                if (tab.diff) |diff| diff.widget.original_editor.model.tokenization().resetTokenization();
            }
        }
    }

    pub fn deinit(self: *Workbench) void {
        for (self.focus_subscriptions) |subscription| if (subscription) |value| value.dispose();
        if (self.terminal_focus_subscription) |subscription| subscription.dispose();
        self.terminal_tabbed_view.on_list_focus = null;
        self.cancelRestoreTimer();
        if (self.context_keys != null) {
            self.terminal_context.deinit();
            self.workbench_context.deinit();
        }
        self.saveSidebarViewStates() catch {};
        if (self.view_state_storage) |state| state.deinit();
        self.view_state_storage = null;
        self.editor_drop_target.deinit();
        self.cancelAsyncJobs();
        if (self.textmate_background) |factory| {
            TokenizationRegistry.instance.setBackgroundTokenizerFactory(null);
            factory.shutdown();
        }
        if (self.breadcrumb_popup) |popup| {
            popup.deinit();
            self.breadcrumb_popup = null;
        }
        self.breadcrumbs.deinit();
        if (self.outline_creator) |*creator| creator.dispose();
        self.context_menu_service.deinit();
        if (self.home_path) |home| {
            self.allocator.free(home);
            self.home_path = null;
        }
        self.breadcrumbs_arena.deinit();
        if (self.references_view_registered) self.references_view.deinit();
        self.builtin_host.deinit();
        self.navigation_arena.deinit();
        if (self.outline_view) |view| {
            view.deinit();
            self.outline_view = null;
        }
        self.outline_service.deinit();
        self.closeSymbolPicker();
        if (self.startup_window == null) self.instantiation.deinit();
        self.services.deinit();
        if (self.media_status) |status| {
            status.deinit();
            self.media_status = null;
        }
        if (self.editor_status) |status| {
            status.deinit();
            self.editor_status = null;
        }
        self.deinitGit();
        self.deinitShellModels();
        if (self.tab_service) |service| service.deinit();
        if (self.global_service) |service| {
            service.deinit();
        }
        if (self.statusbar_service) |service| service.deinit();
        self.user_keybindings.destroy();
        if (self.context_keys) |service| {
            service.deinit();
            self.allocator.destroy(service);
        }
        if (self.theme_palette) |palette| self.allocator.destroy(palette);
        if (self.syntax_theme_ready) self.syntax_theme.deinit();
        if (self.theme_service) |service| service.deinit();
        self.quick_access.deinit();
        self.working_copy_service.deinit();
        self.menu_service.deinit();
        self.commands.deinit();
        self.history.deinit();
        // Dispose the service (and unregister editor listeners) before tab
        // inputs/emitters are destroyed.
        self.part.disposeGroupModelListeners();
        self.service.deinit();
        if (self.sidebar) |sidebar| sidebar.deinit();
        self.destroySearch();
        if (self.settings_watcher) |watcher| watcher.deinit();
        if (self.workspace_watcher) |watcher| {
            watcher.deinit();
            self.workspace_watcher = null;
        }
        if (self.file_watcher_service) |service| {
            service.deinit();
            self.file_watcher_service = null;
        }
        self.contributions.deinit();
        self.on_will_shutdown.deinit();
        self.on_did_shutdown.deinit();
        self.lifecycle.deinit();
        if (self.configuration) |configuration| configuration.deinit();
        freeOwnedPaths(self.allocator, self.user_settings_paths);
        self.workspace.deinit();
        // The part owns the group views; disposing it disposes the tab views.
        self.part.deinit();
        if (self.layout.main_container) |main| main.document.destroy(main);
        self.terminal_tabbed_view.deinit(self.allocator);
        if (self.terminal_service) |service| {
            service.deinit();
            self.terminal_service = null;
        }
        if (self.textmate_background) |factory| {
            factory.deinit();
            self.textmate_background = null;
        }
        self.images.deinit();
        if (self.snippet_registration) |registration| registration.dispose();
        self.snippet_provider.deinit();
        if (self.word_completion_registration) |registration| registration.dispose();
        if (self.word_completion_provider) |provider| self.allocator.destroy(provider);
        if (self.marker_decorations) |service| service.deinit();
        if (self.marker_listener) |listener| {
            if (self.marker_service) |service| service.on_marker_changed.unlisten(listener);
            self.marker_listener = null;
        }
        if (self.marker_service) |service| {
            service.deinit();
            self.allocator.destroy(service);
        }
        if (self.language_features) |service| {
            service.deinit();
            self.allocator.destroy(service);
        }
        self.frame.deinit();
        self.reload_jobs.deinit();
        self.text_file_service.deinit();
        self.disk_files.deinit();
        self.async_io_state.deinit();
        self.allocator.destroy(self);
    }

    /// The terminal supplies only its cell dimensions and a view of the
    /// registered parts. Layout owns the grid and size constraints.
    pub fn geometry(self: *const Workbench) workbench_layout.TerminalGeometry {
        return .{ .layout = &self.layout, .cols = self.cols, .rows = self.rows, .part = self.part, .sidebar_part = &self.sidebar_part, .activity_bar_part = &self.activity_bar_part, .panel_part = &self.panel_part, .sidebar_available = self.sidebar != null };
    }

    /// The Terminal container is active and has at least one instance.
    pub fn terminalVisible(self: *const Workbench) bool {
        if (!self.geometry().panelShown()) return false;
        if (!std.mem.eql(u8, self.geometry().activePanelId(), TERMINAL_CONTAINER_ID)) return false;
        return self.terminal_service != null and self.terminal_service.?.count() > 0;
    }

    /// Editor content height: the rows above the workbench status bar minus the
    /// group chrome (tab strip plus the optional breadcrumb row).
    fn editorContentHeight(self: *Workbench) usize {
        return @max(self.geometry().editorRows() -| self.chromeHeight(), 1);
    }

    fn chromeHeight(self: *Workbench) usize {
        const tabs: usize = if (self.part.part_options.show_tabs == .none) 0 else editor_group_view.title_height;
        return tabs + (if (self.breadcrumbs.settings.enabled) editor_group_view.breadcrumbs_height else 0);
    }

    pub fn setSidebarVisible(self: *Workbench, visible: bool) !void {
        try self.layout.setPartHidden(!visible, .sidebar);
        if (visible) try self.syncActivityBarVisibility();
    }

    fn onGridChanged(_: void, self: *Workbench) !void {
        self.layoutAll();
        self.updatePartFocus() catch {};
    }

    /// Port of the composite action collection: the active side bar view
    /// container supplies the title toolbar actions.
    pub fn updateSidebarTitleActions(self: *Workbench) void {
        const container = self.sidebar_part.pane.active_id orelse "";
        if (std.mem.eql(u8, container, "search")) {
            const view = self.search_view orelse return;
            const tree_mode = view.controller.viewMode() == .tree;
            const expanded = view.hasExpandedResults();
            const has_results = view.matchCount() != 0;
            self.sidebar_part.pane.setTitleActions(&.{
                .{ .id = search_command_ids.refresh_search_results, .label = "Refresh", .glyph = '↻', .enabled = view.widget.value(.search).len != 0 },
                .{ .id = search_command_ids.clear_search_results, .label = "Clear Search Results", .glyph = '×', .enabled = has_results },
                // Codicon.listFlat/listTree fit one cell. U+2637 (☷) is a
                // wide character and displaces later glyphs and frame strokes.
                if (tree_mode)
                    .{ .id = search_command_ids.view_as_list, .label = "View as List", .glyph = 0xeb84 }
                else
                    .{ .id = search_command_ids.view_as_tree, .label = "View as Tree", .glyph = 0xeb86 },
                if (expanded or !has_results)
                    .{ .id = search_command_ids.collapse_search_results, .label = "Collapse All", .glyph = '⊟', .enabled = has_results }
                else
                    .{ .id = search_command_ids.expand_search_results, .label = "Expand All", .glyph = '⊞' },
            }, &.{}) catch {};
        } else if (std.mem.eql(u8, container, "scm")) {
            const merged = if (self.scm_container) |value|
                value.mergedTitleActions(self.allocator) catch null
            else
                null;
            // The container overflow includes a merged pane's secondary actions.
            // Keep only its primary buttons in the shared title toolbar.
            var primary = merged orelse &.{};
            if (primary.len > 0) {
                const last = primary[primary.len - 1].id;
                if (std.mem.eql(u8, last, scm_view_mod.CHANGES_MENU_ACTION_ID) or
                    std.mem.eql(u8, last, scm_history_view_mod.GRAPH_MENU_ACTION_ID) or
                    std.mem.eql(u8, last, OutlinePane.more_actions_id))
                    primary = primary[0 .. primary.len - 1];
            }
            self.sidebar_part.pane.setTitleActions(primary, &.{
                .{ .id = "workbench.scm.action.showMenu", .label = "More Actions", .glyph = '…' },
            }) catch {};
        } else if (std.mem.eql(u8, container, "explorer")) {
            const merged = if (self.explorer_container) |value| value.mergedTitleActions(self.allocator) catch null else null;
            self.sidebar_part.pane.setTitleActions(merged orelse &.{}, &.{}) catch {};
        } else {
            self.sidebar_part.pane.setTitleActions(&.{}, &.{}) catch {};
        }
    }

    fn sidebarMenuAnchor(self: *Workbench, id: []const u8) MenuAnchor {
        if (self.sidebar_action_anchor) |anchor| return anchor;
        if (self.activeSidebarViewContainer()) |container| {
            if (container.titleActionRect(id)) |rect| return .{ .x = ui.cell.snap(rect.x), .y = ui.cell.snap(rect.bottom()) };
        }
        const rect = self.geometry().sidebarRect();
        return .{ .x = ui.cell.snap(rect.right()) -| 1, .y = ui.cell.snap(rect.y) + 1 };
    }

    pub fn runSidebarTitleAction(self: *Workbench, id: []const u8, event: ?*const ui.MouseEvent) void {
        const previous = self.sidebar_action_anchor;
        defer self.sidebar_action_anchor = previous;
        self.sidebar_action_anchor = if (event) |e| MenuAnchor.mouse(e) else null;
        self.commands.execute(id) catch {};
    }

    pub fn activeActivity(self: *const Workbench) usize {
        return self.activity_bar_part.activeIndex() orelse 0;
    }

    /// Shows the activity container with `id` (for example `workbench.view.scm`).
    pub fn showActivityById(self: *Workbench, id: []const u8) !bool {
        for (self.activity_bar_part.activities.items) |activity| {
            if (!std.mem.eql(u8, activity.id, id)) continue;
            try self.openActivity(activity.id, true);
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

    /// Sets the workspace folders and rebuilds the Explorer roots. Upstream
    /// the workspace context service is set by the workbench startup; here the
    /// CLI folder arguments replace the empty workspace.
    pub fn setWorkspaceFolders(self: *Workbench, folders: []const []const u8) !void {
        const replacement = try WorkspaceContextService.initWithFolders(self.allocator, "workspace", folders);
        var replacement_owned = false;
        errdefer if (!replacement_owned) replacement.deinit();
        if (self.sidebar) |sidebar| {
            sidebar.deinit();
            self.sidebar = null;
        }
        self.destroySearch();
        // The contribution watches the current workspace/configuration; stop
        // it before either is replaced and recreate it below when startup has
        // already reached the AfterRestored phase.
        if (self.workspace_watcher) |watcher| {
            watcher.deinit();
            self.workspace_watcher = null;
        }
        if (self.settings_watcher) |watcher| {
            watcher.deinit();
            self.settings_watcher = null;
        }
        self.breadcrumbs.detachServices();
        if (self.configuration) |configuration| {
            if (self.terminal_service) |service| service.options.configuration = null;
            self.git_model.detachConfiguration();
            self.scm.detachConfiguration();
            if (self.theme_service) |service| service.detachConfiguration();
            if (self.notification_controller) |controller| try controller.attachConfiguration(null);
            configuration.deinit();
            self.configuration = null;
        }
        // Stop the quick-open listing while the old workspace snapshot is
        // still alive; the worker owns copies, but this keeps the ordering
        // explicit and drops picker items that borrow old paths.
        self.quick_access.endFileSession();
        if (self.terminal_service) |service| service.options.workspace_root = null;
        self.saveSidebarViewStates() catch {};
        self.workspace.deinit();
        self.workspace = replacement;
        replacement_owned = true;
        if (self.view_state_storage != null) {
            const has_scm = self.scm_view_model != null;
            const has_history = if (self.git_model.repository) |provider| provider.historyProvider() != null else false;
            if (self.explorer_view_model) |model| try addSidebarViewDescriptors(model, has_scm, has_history);
            if (self.scm_view_model) |model| try addSidebarViewDescriptors(model, has_scm, has_history);
            try self.restoreSidebarViewStates();
            self.updateSidebarTitleActions();
        }
        try self.ensureConfiguration();
        if (self.terminal_service) |service| {
            service.options.workspace_root = self.workspaceFolderPath();
            service.options.multi_root = self.workspace.getWorkspace().folders.items.len > 1;
        }
        self.layoutAll();
        try self.quick_access.setWorkspace(self.workspace);
        if (self.lifecycle.phase.reached(.Restored) and self.workspace.getWorkspace().folders.items.len > 0) {
            self.ensureWorkspaceWatcher() catch |err| {
                std.log.scoped(.file_watcher).err("failed to start workspace watcher: {s}", .{@errorName(err)});
            };
        }
    }

    /// Sets the user settings files before the Explorer/configuration service
    /// is created. The app derives them from the VS Code profile and the
    /// terminal's own config directory; later layers override earlier ones.
    pub fn setUserConfigurationValue(self: *Workbench, key: []const u8, value: ?std.json.Value) !void {
        const configuration = self.configuration orelse return error.ConfigurationUnavailable;
        try configuration.updateValue(key, value, @import("../../platform/configuration/common/configuration.zig").ConfigurationTarget.USER);
    }

    pub fn setUserSettingsPaths(self: *Workbench, paths: []const []const u8) !void {
        freeOwnedPaths(self.allocator, self.user_settings_paths);
        self.user_settings_paths = try dupeOwnedPaths(self.allocator, paths);
        if (self.configuration) |configuration| {
            self.breadcrumbs.detachServices();
            if (self.workspace_watcher) |watcher| {
                watcher.deinit();
                self.workspace_watcher = null;
            }
            if (self.settings_watcher) |watcher| {
                watcher.deinit();
                self.settings_watcher = null;
            }
            if (self.terminal_service) |service| service.options.configuration = null;
            self.git_model.detachConfiguration();
            self.scm.detachConfiguration();
            if (self.theme_service) |service| service.detachConfiguration();
            if (self.notification_controller) |controller| try controller.attachConfiguration(null);
            configuration.deinit();
            self.configuration = null;
            try self.ensureConfiguration();
            self.configureJsonLanguage();
            try self.layout.onZenModeConfigurationChange(null);
            self.applyEditorSettingsToAllTabs();
            self.layoutAll();
            if (self.lifecycle.phase.reached(.Restored) and self.workspace.getWorkspace().folders.items.len > 0) {
                self.ensureWorkspaceWatcher() catch |err| {
                    std.log.scoped(.file_watcher).err("failed to restart workspace watcher: {s}", .{@errorName(err)});
                };
            }
        }
    }

    /// Sets the user keybinding files. They are watched by the settings
    /// watcher; the keymap itself is rebuilt by the keybinding phase.
    pub fn setKeybindingsPaths(self: *Workbench, paths: []const []const u8) !void {
        try self.user_keybindings.setPaths(paths, self.ensureFileService() catch null);
    }

    fn ensureConfiguration(self: *Workbench) !void {
        if (self.configuration != null) return;
        self.configuration = try ConfigurationService.init(
            self.allocator,
            self.io,
            self.workspace,
            .{
                .user_settings_paths = self.user_settings_paths,
                .defaults_json = &.{
                    search_configuration.defaults_json,
                    terminal_configuration.defaults_json,
                    theme_configuration_mod.defaults_json,
                    workbench_configuration.defaults_json,
                    zen_mode_contribution.defaults_json,
                },
            },
        );
        const themes = try self.ensureThemeService();
        try themes.setConfiguration(self.configuration.?);
        try self.git_model.setConfiguration(self.configuration);
        try self.scm.setConfiguration(self.configuration);
        if (self.notification_controller) |controller| try controller.attachConfiguration(self.configuration);
        try self.configuration.?.onDidChangeConfiguration(self, onWorkbenchConfigurationChange);
        if (self.declarative) |catalog| try self.applyExtensionDefaults(catalog);
        if (self.terminal_service) |service| service.options.configuration = self.configuration;
        self.settings_watcher = SettingsWatcher.init(self.allocator, self.io, self.configuration.?, try self.ensureFileService(), &self.window_events) catch null;
        if (self.settings_watcher) |watcher| {
            watcher.setOnReload(.{ .context = self, .callback = onSettingsReloaded });
            watcher.setAsyncIo(self.async_io);
        }
        try self.breadcrumbs.attachServices(self.workspace, self.configuration);
        self.applyLayoutSettings(null);
    }

    fn onWorkbenchConfigurationChange(change: configuration_mod.Change, self: *Workbench) !void {
        const config = @import("../../platform/configuration/common/configuration.zig");
        if (config.affectsConfiguration(change, "workbench") or config.affectsConfiguration(change, "zenMode")) {
            self.applyLayoutSettings(change);
            try self.layout.onZenModeConfigurationChange(change);
        }
        if (config.affectsConfiguration(change, "scm") or config.affectsConfiguration(change, "git") or
            config.affectsConfiguration(change, "explorer.decorations") or config.affectsConfiguration(change, "workbench.tree.renderIndentGuides"))
        {
            self.requestFrame();
        }
        if (config.affectsConfiguration(change, layout_service_mod.LayoutSettings.editor_centered_layout_auto_resize) or
            config.affectsConfiguration(change, "diffEditor.renderSideBySide"))
        {
            try self.layout.centerMainEditorLayout(self.layout.isMainEditorCentered(), false);
        }
        if (config.affectsConfiguration(change, "editor")) self.applyEditorSettingsToAllTabs();
    }

    fn onSettingsReloaded(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.applyConfiguredLanguageAssociationsToAllEditors();
        if (self.search_view) |view| view.onConfigurationChanged();
        self.applyMarkdownPreviewConfig();
        if (self.git_model.repository != null) self.refreshGitStatus();
    }

    fn editorSettingsReader(self: *Workbench) terminal_editor_config.Reader {
        return .{ .context = self, .get_value = readEditorSetting };
    }

    fn applyEditorSettingsToTab(self: *Workbench, tab: *Tab) void {
        if (tab.isDiff()) {
            if (self.layout.zen_hide_line_numbers) self.applyLineNumbersOverrideToTab(tab, .Off);
            return;
        }
        const reader = self.editorSettingsReader();
        const language_id = tab.editor.languageId();
        const resource = tab.editor.path;
        _ = tab.editor.applyEditorSettings(reader, language_id, resource) catch false;
        _ = tab.view.applyEditorSettings(reader, language_id, resource) catch false;
        // Zen mode's temporary line-number override, matching upstream
        // `updateOptions({ lineNumbers: 'off' })`. The next
        // `applyEditorSettings` after the override is cleared restores the
        // configured value.
        if (tab.search_editor_input) |input| {
            if (self.configuration) |configuration| input.search_editor.configure(configuration);
            tab.view.applyLineNumbersOverride(.Off) catch {};
        } else if (self.layout.zen_hide_line_numbers and !tab.isImage()) {
            tab.view.applyLineNumbersOverride(.Off) catch {};
        }
        if (self.theme_palette) |palette| tab.view.setThemeColors(palette);
        if (self.theme_palette) |palette| {
            if (tab.image_preview) |pane| pane.setThemeColors(palette);
        }
    }

    fn applyEditorSettingsToAllTabs(self: *Workbench) void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| self.applyEditorSettingsToTab(tab);
        }
    }

    /// Port of the `setLineNumbers()` restore path in `toggleZenMode`: read
    /// `editor.lineNumbers` per editor (the configured value, or upstream's
    /// `on` default) and write it back after the zen override is cleared.
    /// `applyEditorSettings` leaves the option untouched when the setting is
    /// absent, so the temporary `off` value would otherwise survive.
    fn restoreLineNumbersFromConfiguration(self: *Workbench) void {
        const reader = self.editorSettingsReader();
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.isImage()) continue;
                const render_type = terminal_editor_config.lineNumbersSetting(
                    reader,
                    tab.editor.languageId(),
                    tab.editor.path,
                ) orelse .On;
                self.applyLineNumbersOverrideToTab(tab, render_type);
            }
        }
    }

    /// Applies a line-number option to a tab's editor view(s). A diff tab has
    /// the original and modified views; upstream's `visibleTextEditorControls`
    /// includes both code editor widgets.
    fn applyLineNumbersOverrideToTab(self: *Workbench, tab: *Tab, render_type: editor_options.RenderLineNumbersType) void {
        _ = self;
        if (tab.diff) |diff| {
            diff.widget.original_view.applyLineNumbersOverride(render_type) catch {};
            diff.widget.modified_view.applyLineNumbersOverride(render_type) catch {};
            return;
        }
        if (tab.isImage()) return;
        tab.view.applyLineNumbersOverride(render_type) catch {};
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

    /// Handles external file changes: clean open editors are reloaded, dirty
    /// ones keep the user's in-memory content (upstream marks the conflict).
    pub fn handleFileChanges(self: *Workbench, changes: []const @import("../../platform/files/common/files.zig").FileChange) void {
        for (changes) |change| {
            if (change.type == .DELETED) continue;
            // FSEvents can report a pre-existing path as ADDED on its first
            // event because it has no initial directory snapshot. For an open
            // editor that is a content change just like UPDATED.
            self.requestFrame();
            for (self.part.group_views.items) |pane| {
                for (pane.tabs.items) |tab| {
                    if (tab.isImage()) {
                        const image_path = tab.imagePath() orelse continue;
                        if (self.samePath(image_path, change.resource)) tab.reloadImage();
                        continue;
                    }
                    if (tab.markdown_preview) |preview| {
                        if (preview.usesImagePath(change.resource)) preview.refresh(false);
                    }
                    if (tab.isDiff()) continue;
                    if (!self.samePath(tab.editor.path, change.resource)) continue;
                    if (tab.editor.isDirty()) {
                        tab.editor.markConflict();
                        continue;
                    }
                    self.requestFileReload(change.resource);
                }
            }
        }
    }

    pub fn workingCopyService(self: *Workbench) *WorkingCopyService {
        return &self.working_copy_service;
    }

    fn registerWorkingCopy(self: *Workbench, tab: *Tab) void {
        tab.editor.undo_redo.setNotificationService(self.notification_api);
        if (self.search_view) |view| view.model.result.onModelAdded(tab.editor.path, tab.editor.model) catch {};
        self.working_copy_service.registerWorkingCopy(tui_editor_mod.workingCopyInterface(tab.editor)) catch {};
    }

    fn unregisterWorkingCopy(self: *Workbench, tab: *Tab) void {
        _ = self.working_copy_service.unregisterWorkingCopy(tui_editor_mod.workingCopyInterface(tab.editor));
    }

    fn initAfterRestoredWorkspaceWatcher(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        try self.ensureWorkspaceWatcher();
    }

    fn ensureFileService(self: *Workbench) !*FileWatcherService {
        if (self.file_watcher_service == null) {
            const service = try FileWatcherService.init(self.allocator, self.io);
            errdefer service.deinit();
            _ = try service.on_did_change.listen(self, onWorkspaceFileChanges);
            service.client.attachWindow(&self.window_events);
            self.file_watcher_service = service;
        }

        return self.file_watcher_service.?;
    }

    fn ensureWorkspaceWatcher(self: *Workbench) !void {
        if (self.workspace.getWorkspace().folders.items.len == 0) return;
        if (self.configuration == null) try self.ensureConfiguration();
        const configuration = self.configuration orelse return;

        if (self.workspace_watcher == null) {
            self.workspace_watcher = try WorkspaceWatcher.init(
                self.allocator,
                configuration,
                self.workspace,
                self.file_watcher_service.?,
                .{ .context = self, .callback = reportWatcherMessage },
            );
        }
        if (self.git_model.repository) |provider| provider.watch(self.file_watcher_service.?) catch {};
    }

    fn onWorkspaceFileChanges(changes: []const @import("../../platform/files/common/files.zig").FileChange, self: *Workbench) !void {
        self.handleFileChanges(changes);
    }

    fn reportWatcherMessage(_: *anyopaque, message: []const u8) void {
        std.log.scoped(.file_watcher).warn("{s}", .{message});
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
        if (tab.isDiff() or tab.terminal_input != null) return;
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
            self.sidebar = try Sidebar.initWithAsyncIo(
                self.allocator,
                self.io,
                self.async_io,
                self.workspace,
                self.configuration.?,
                &self.window_events,
            );
        }
        if (self.search_view == null) try self.initSearchFromWorkspace();
        self.sidebar.?.theme_service = self.theme_service;
        self.sidebar.?.setOpenEditorQuery(.{ .context = self, .is_open = isPathOpen });
        try self.setSidebarVisible(true);
        _ = try self.activity_bar_part.setActive(self.activity_bar_part.activities.items[0].id);
        _ = try self.sidebar_part.openPaneComposite(self.activity_bar_part.activities.items[0].id);
        self.updateSidebarTitleActions();
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
            .open_files = searchOpenFiles,
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
                .open_results = searchOpenResults,
                .highlight_range = searchHighlightRange,
                .read_file = searchReadFile,
                .extra_files = searchExtraFiles,
                .free_paths = searchFreePaths,
                .apply_edits = searchApplyEdits,
                .save_file = searchSaveFile,
                .active_selection_text = searchActiveSelectionText,
                .confirm_replace_all = searchConfirmReplaceAll,
            },
        );
        errdefer view.deinit();
        try view.attachActivity(&self.activity_service);
        view.model.result.model_host = .{ .context = self, .get = searchTextModel, .queue = &self.window_events };
        self.search_service = service;
        view.model.delivery.attach(&self.window_events, view, SearchView.dispatchSearch);
        self.search_view = view;
    }

    fn destroySearch(self: *Workbench) void {
        if (self.search_view) |view| view.deinit();
        self.search_view = null;
        if (self.search_service) |service| self.allocator.destroy(service);
        self.search_service = null;
    }

    /// The activity-bar ellipsis lists the entries that do not fit the rail.
    pub fn showActivityOverflowMenu(self: *Workbench, event: *const ui.MouseEvent) !void {
        const rect = self.geometry().activityRect();
        const capacity = activity_bar_mod.visibleCapacity(rect);
        if (!activity_bar_mod.overflowVisible(&self.activity_bar_part, rect)) return;
        const shown = capacity -| 1;
        const menu = try self.newContextMenu(runActivityOverflowAction);
        errdefer menu.deinit();
        const arena = menu.arena.allocator();
        var visible_index: usize = 0;
        for (self.activity_bar_part.activities.items) |activity| {
            if (!activity.visible) continue;
            defer visible_index += 1;
            if (visible_index < shown) continue;
            try menu.add(try std.fmt.allocPrint(arena, "activity:{s}", .{activity.id}), .{ .label = activity.name, .type = .radio, .checked = std.mem.eql(u8, self.activity_bar_part.active_id orelse "", activity.id) });
        }
        if (menu.items.items.len == 0) {
            menu.deinit();
            return;
        }
        try self.showContextMenu(menu, MenuAnchor.mouse(event));
    }

    pub fn showActivity(self: *Workbench, index: usize) !void {
        const activity = self.activity_bar_part.activityAtVisibleIndex(index) orelse return;
        try self.openActivity(activity.id, true);
    }

    fn openActivity(self: *Workbench, id: []const u8, focus: bool) !void {
        if (self.sidebar == null or self.search_view == null) try self.initSidebarFromWorkspace();
        // Switching the visible view container invalidates the hover state
        // painted by the previous one.
        self.clearSidebarViewHover();
        if (self.activeSidebarViewContainer()) |container| container.cancelHeaderDrag();
        _ = try self.activity_bar_part.setActive(id);
        _ = try self.sidebar_part.openPaneComposite(id);
        try self.setSidebarVisible(true);
        try self.syncActivityBarVisibility();
        self.updateSidebarTitleActions();
        if (focus) {
            self.setFocus(.sidebar);
            self.statusbar.main_part.clearFocus();
            if (std.mem.eql(u8, id, "search")) {
                if (self.search_view) |view| view.focus();
            }
        }
        if (self.range_highlights) |highlights| highlights.removeHighlightRange();
        self.layoutAll();
    }

    pub fn toggleSidebar(self: *Workbench) !void {
        if (self.sidebar == null) {
            try self.initSidebarFromWorkspace();
            self.setFocus(.sidebar);
            return;
        }
        const visible = !self.layout.isVisible(.sidebar);
        try self.setSidebarVisible(visible);
        self.setFocus(if (visible) .sidebar else .editor);
        self.statusbar.main_part.clearFocus();
        if (!visible) {
            if (self.range_highlights) |highlights| highlights.removeHighlightRange();
        }
        self.layoutAll();
    }

    pub fn focusSidebar(self: *Workbench) void {
        if (!self.geometry().sidebarShown()) return;
        self.setFocus(.sidebar);
        self.updateProblemsHighlight();
        if (self.breadcrumbs.activeControl()) |control| control.setFocused(false);
        self.statusbar.main_part.clearFocus();
        if (std.mem.eql(u8, self.activity_bar_part.active_id orelse "", "search")) {
            if (self.search_view) |view| view.focus();
        }
    }

    pub fn focusEditor(self: *Workbench) void {
        self.setFocus(.editor);
        if (self.activeSidebarViewContainer()) |container| {
            container.cancelHeaderDrag();
            container.focused_header = null;
        }
        if (self.scm.changes) |view| view.blurInput();
        if (self.range_highlights) |highlights| highlights.removeHighlightRange();
        if (self.breadcrumbs.activeControl()) |control| control.setFocused(false);
        self.statusbar.main_part.clearFocus();
        if (self.search_view) |view| view.blur();
    }

    pub fn focusStatusBar(self: *Workbench) void {
        if (!self.geometry().statusBarVisible()) return;
        self.setFocus(.statusbar);
        self.updateProblemsHighlight();
        if (self.range_highlights) |highlights| highlights.removeHighlightRange();
        if (self.breadcrumbs.activeControl()) |control| control.setFocused(false);
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
        if (self.problems_view != null) return;
        self.problems_view = MarkersView.init(self.allocator);
        errdefer {
            self.problems_view.?.deinit();
            self.problems_view = null;
        }
        try self.problems_view.?.attach(self.marker_service, .{
            .context = self,
            .open_editor = problemsOpenEditor,
            .selection_changed = problemsSelectionChanged,
            .workspace_root = problemsWorkspaceRoot,
            .focus_editor = problemsFocusEditor,
        });
    }

    /// Upstream `workbench.actions.view.problems`: open the Problems container
    /// in the panel and move focus to the list.
    pub fn showProblems(self: *Workbench) !void {
        try self.ensureProblemsView();
        if (!try self.panel_part.openPaneComposite(PROBLEMS_CONTAINER_ID)) return;
        try self.syncPanelContainerVisibility();
        self.setFocus(.problems);
        self.statusbar.main_part.clearFocus();
        if (self.breadcrumbs.activeControl()) |control| control.setFocused(false);
        if (self.search_view) |view| view.blur();
        self.updateProblemsHighlight();
        self.layoutAll();
    }

    pub fn toggleProblems(self: *Workbench) !void {
        // Upstream `ToggleMarkersViewAction` toggles on
        // `viewsService.isViewVisible`, i.e. whether the container is the
        // visible panel container, not whether the list owns focus.
        if (self.problemsVisible()) {
            // `viewsService.closeView` on the only view of a panel container
            // hides the part through `hideActivePaneComposite`.
            self.closeActivePanelContainer();
            return;
        }
        try self.showProblems();
    }

    fn closeActivePanelContainer(self: *Workbench) void {
        self.panel_part.hideActivePaneComposite() catch {};
        self.panel_part.setHovered(null);
        if (self.focus == .terminal or self.focus == .problems) {
            self.setFocus(.editor);
        }
        self.updateProblemsHighlight();
        self.layoutAll();
    }

    fn problemsVisible(self: *const Workbench) bool {
        return self.geometry().panelShown() and std.mem.eql(u8, self.geometry().activePanelId(), PROBLEMS_CONTAINER_ID);
    }

    fn problemsFocused(self: *const Workbench) bool {
        return self.focus == .problems and self.problemsVisible();
    }

    /// Hides the panel without clearing the active container, like upstream
    /// `TogglePanelAction`.
    pub fn hidePanel(self: *Workbench) void {
        self.panel_part.setHovered(null);
        self.layout.setPartHidden(true, .panel) catch {};
        if (self.focus == .terminal or self.focus == .problems) {
            self.setFocus(.editor);
        }
        self.updateProblemsHighlight();
        self.layoutAll();
    }

    /// Reveals `id` in the panel and moves focus to it.
    pub fn openPanelContainer(self: *Workbench, id: []const u8) !bool {
        if (!try self.panel_part.openPaneComposite(id)) return false;
        try self.syncPanelContainerVisibility();
        if (std.mem.eql(u8, id, PROBLEMS_CONTAINER_ID)) {
            try self.ensureProblemsView();
            self.setFocus(.problems);
        } else if (std.mem.eql(u8, id, TERMINAL_CONTAINER_ID)) {
            self.setFocus(.terminal);
        }
        self.statusbar.main_part.clearFocus();
        if (self.breadcrumbs.activeControl()) |control| control.setFocused(false);
        if (self.search_view) |view| view.blur();
        self.updateProblemsHighlight();
        self.layoutAll();
        return true;
    }

    /// Panel container used when the panel is revealed without an explicit
    /// id: the last active composite, else the first visible one.
    fn defaultPanelContainerId(self: *Workbench) ?[]const u8 {
        if (self.panel_part.pane.last_active_id) |id| return id;
        if (self.panel_part.pane.active_id) |id| return id;
        for (self.panel_part.pane.bar.items.items) |item| {
            if (item.visible) return item.id;
        }
        return if (self.view_descriptor_service.getDefaultViewContainer(.panel)) |container| container.id else null;
    }

    /// Cycles the visible panel containers, like
    /// `workbench.action.previousPanelView`/`nextPanelView`.
    fn cyclePanelView(self: *Workbench, delta: isize) !bool {
        if (!self.geometry().panelShown()) return false;
        const items = self.panel_part.pane.bar.items.items;
        var visible_count: usize = 0;
        for (items) |item| {
            if (item.visible) visible_count += 1;
        }
        if (visible_count < 2) return false;
        var current: isize = -1;
        for (items, 0..) |item, index| {
            if (!item.visible) continue;
            if (std.mem.eql(u8, item.id, self.geometry().activePanelId())) {
                current = @intCast(index);
                break;
            }
        }
        if (current < 0) return false;
        var step: isize = 1;
        while (step <= @as(isize, @intCast(items.len))) : (step += 1) {
            const next_index = @mod(current + delta * step, @as(isize, @intCast(items.len)));
            const item = items[@intCast(next_index)];
            if (!item.visible) continue;
            _ = try self.openPanelContainer(item.id);
            return true;
        }
        return false;
    }

    /// Keeps the composite-bar title items in sync with `hideIfEmpty`: a
    /// container is listed while it has content, or while it is the active
    /// container (opening an empty Problems view re-shows its title).
    fn syncPanelContainerVisibility(self: *Workbench) !void {
        const stats = if (self.marker_service) |service| service.getStatistics() else markers_mod.MarkerStatistics{};
        const problems_has_content = stats.errors + stats.warnings + stats.infos > 0;
        const problems_active = std.mem.eql(u8, self.geometry().activePanelId(), PROBLEMS_CONTAINER_ID);
        _ = try self.panel_part.pane.setPaneCompositeVisible(PROBLEMS_CONTAINER_ID, problems_has_content or problems_active);

        const terminals = if (self.terminal_service) |service| service.count() else 0;
        const terminal_active = std.mem.eql(u8, self.geometry().activePanelId(), TERMINAL_CONTAINER_ID);
        _ = try self.panel_part.pane.setPaneCompositeVisible(TERMINAL_CONTAINER_ID, terminals > 0 or terminal_active);
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
        const view = if (self.problems_view) |*view| view else {
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
        highlights.highlightRange(tab.editor.path, tab.editor.model.validateRange(MarkersView.markerRange(marker)));
    }

    pub fn setTerminalProfileStorage(self: *Workbench, user_data_dir: []const u8) !void {
        try self.terminal_tabbed_view.setProfileStorage(self.allocator, self.io, user_data_dir);
    }

    pub fn terminalFocused(self: *const Workbench) bool {
        return self.focusedTerminal() != null;
    }

    pub fn ensureTerminalService(self: *Workbench) !*TerminalService {
        if (self.terminal_service) |service| return service;
        const service = try TerminalService.init(self.allocator, self.io, .{
            .workspace_root = self.workspaceFolderPath(),
            .configuration = self.configuration,
            .multi_root = self.workspace.getWorkspace().folders.items.len > 1,
        });
        try self.attachTerminalService(service);
        return service;
    }

    pub fn attachTerminalService(self: *Workbench, service: *TerminalService) !void {
        errdefer service.deinit();
        self.terminal_focus_subscription = try service.group.on_did_change_active_instance.listenSignal(self, updatePartFocus);
        errdefer {
            self.terminal_focus_subscription.?.dispose();
            self.terminal_focus_subscription = null;
        }
        if (self.context_keys != null) try self.terminal_context.attach(service);
        self.terminal_service = service;
    }

    pub fn showTerminal(self: *Workbench) !void {
        const service = try self.ensureTerminalService();
        if (service.count() == 0) _ = try service.create();
        self.terminal_tabbed_view.setListFocused(false);
        _ = try self.openPanelContainer(TERMINAL_CONTAINER_ID);
        self.revealActiveTerminalTab();
    }

    pub fn hideTerminal(self: *Workbench) void {
        self.hidePanel();
    }

    pub fn toggleTerminal(self: *Workbench) !void {
        try self.terminal_action_services.run(.toggle);
    }

    fn terminalConfig(self: *const Workbench) terminal_configuration.Config {
        return terminal_configuration.Config.load(self.configuration);
    }

    pub fn focusedTerminal(self: *const Workbench) ?*terminal_service_mod.TerminalInstance {
        if (self.focus == .terminal and self.terminalVisible()) return self.terminal_tabbed_view.focusedInstance(self.terminal_service.?);
        if (self.focus != .editor) return null;
        const pane = self.part.viewForGroup(self.service.activeGroup()) orelse return null;
        const tab = pane.activeTab() orelse return null;
        return tab.terminalInstance();
    }

    pub fn newTerminal(self: *Workbench) !void {
        try self.terminal_action_services.run(.new);
    }

    pub fn launchTerminalProcess(self: *Workbench, name: []const u8, executable: []const u8, args: []const []const u8, cwd: ?[]const u8) !*terminal_service_mod.TerminalInstance {
        const service = try self.ensureTerminalService();
        const instance = try service.createForTask(.{ .path = executable, .args = args, .profile_name = name }, cwd);
        self.terminal_tabbed_view.setListFocused(false);
        _ = try self.openPanelContainer(TERMINAL_CONTAINER_ID);
        self.revealActiveTerminalTab();
        return instance;
    }

    pub fn newPanelTerminal(self: *Workbench) !void {
        try self.terminal_action_services.newPanelTerminal();
    }

    fn openTerminalEditorWithProfile(context: *anyopaque, profile: terminal_platform.ITerminalProfile) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const pane = self.activePane() orelse return error.GroupPaneMissing;
        const service = try self.ensureTerminalService();
        _ = try service.createEditorWithProfile(self.view_factory, pane, profile, true);
        self.revealTerminalEditor();
    }

    pub fn createTerminalInEditor(self: *Workbench, pane: *GroupPane, parent: ?*terminal_service_mod.TerminalInstance) !*Tab {
        const service = try self.ensureTerminalService();
        const tab = try service.createEditor(self.view_factory, pane, parent);
        self.revealTerminalEditor();
        return tab;
    }

    fn revealTerminalEditor(self: *Workbench) void {
        self.layoutAll();
        self.focusEditor();
    }

    pub fn openTerminalEditorToSide(self: *Workbench, parent: ?*terminal_service_mod.TerminalInstance) !void {
        try self.terminal_action_services.openEditorToSide(parent);
    }

    pub fn movePanelInstanceToEditor(self: *Workbench, service: *TerminalService, pane: *GroupPane, index: usize) !void {
        try service.moveToEditor(self.view_factory, pane, index);
        try self.revealTerminalEditorMoved(true);
    }

    pub fn revealTerminalEditorMoved(self: *Workbench, moved: bool) !void {
        if (moved) {
            if (self.terminal_service.?.count() == 0 and self.terminalPanelActive()) self.hidePanel();
            try self.syncPanelContainerVisibility();
        }
        self.revealTerminalEditor();
    }

    fn moveTerminalToPanel(self: *Workbench, pane: *GroupPane, tab: *Tab) !void {
        if (tab.terminal_input == null) return;
        const service = self.terminal_service orelse return;
        try service.moveToTerminalView(pane, tab, self.closeEditorHost());
        try self.showTerminal();
    }

    pub fn killTerminal(self: *Workbench) !void {
        try self.terminal_action_services.run(.kill);
    }

    pub fn killPanelTerminal(self: *Workbench, index: usize) !void {
        const service = self.terminal_service orelse return;
        service.kill(index);
        try self.onPanelTerminalsRemoved(service);
    }

    pub fn onPanelTerminalsRemoved(self: *Workbench, service: *TerminalService) !void {
        if (service.count() == 0) {
            if (self.terminalPanelActive() and self.terminalConfig().hide_on_last_closed) self.hidePanel();
            try self.syncPanelContainerVisibility();
        }
        self.layoutAll();
        self.revealActiveTerminalTab();
    }

    pub fn focusPanelPane(self: *Workbench, next: bool) bool {
        return self.terminal_action_services.focusPane(next);
    }

    pub fn focusTerminalListRow(self: *Workbench, next: bool) void {
        const service = self.terminal_service orelse return;
        self.terminal_tabbed_view.focusListRow(service, self.geometry().panelRect(), next);
    }

    pub fn terminalPanelActive(self: *const Workbench) bool {
        return self.geometry().panelShown() and std.mem.eql(u8, self.geometry().activePanelId(), TERMINAL_CONTAINER_ID);
    }

    fn revealActiveTerminalTab(self: *Workbench) void {
        const service = self.terminal_service orelse return;
        self.terminal_tabbed_view.revealActive(service, self.geometry().panelRect());
    }

    pub fn focusTerminal(self: *Workbench) !void {
        try self.terminal_action_services.run(.focus);
    }

    pub fn focusNextTerminal(self: *Workbench) void {
        self.terminal_action_services.run(.focus_next) catch {};
    }

    pub fn focusPreviousTerminal(self: *Workbench) void {
        self.terminal_action_services.run(.focus_previous) catch {};
    }

    pub fn resizeTerminalPanel(self: *Workbench, delta: isize) void {
        if (!self.geometry().panelShown()) return;
        const current: isize = @intCast(self.geometry().panelHeight());
        self.resizePanelTo(@intCast(@max(current +| delta, 0)));
    }

    pub fn resizePanelTo(self: *Workbench, desired: usize) void {
        const height = self.geometry().clampPanelHeight(desired);
        if (height == self.geometry().panelHeight()) return;
        self.layout.setSize(.panel, height) catch {};
        self.layoutAll();
    }

    pub fn terminalAcceptsPaste(self: *const Workbench) bool {
        return self.terminalFocused() and self.context_menu_service.current == null and !self.quick_access.isOpen() and !self.isDialogOpen();
    }

    pub fn splitTerminalTabs(self: *Workbench, index: usize) !void {
        const service = self.terminal_service orelse return;
        try service.splitSelectedTabs(index);
        try self.showTerminal();
    }

    pub fn killTerminalTabs(self: *Workbench, index: usize) !void {
        const service = self.terminal_service orelse return;
        service.killSelectedTabs(index);
        try self.onPanelTerminalsRemoved(service);
    }

    pub fn showTerminalSwitchMenu(self: *Workbench, event: *const ui.MouseEvent) !void {
        const service = self.terminal_service orelse return;
        if (service.count() == 0) return;
        const menu = try self.newContextMenu(onTerminalMenu);
        errdefer menu.deinit();
        try terminal_actions.appendSwitchMenu(service, menu);
        try self.showContextMenu(menu, MenuAnchor.mouse(event));
    }

    pub fn showTerminalProfileMenu(self: *Workbench, group_id: ?editor_mod.GroupIdentifier, event: *const ui.MouseEvent) !void {
        const service = self.terminal_service orelse return;
        const menu = try self.newContextMenu(onTerminalMenu);
        errdefer menu.deinit();
        try terminal_actions.appendProfileMenu(service, menu, group_id);
        if (menu.items.items.len == 0) {
            menu.deinit();
            return;
        }
        try self.showContextMenu(menu, MenuAnchor.mouse(event));
    }

    pub fn showTerminalTabMenu(self: *Workbench, index: usize, event: *const ui.MouseEvent) !void {
        const service = self.terminal_service orelse return;
        if (service.at(index) == null) return;
        const menu = try self.newContextMenu(onTerminalMenu);
        errdefer menu.deinit();
        try terminal_actions.appendTabMenu(service, menu, index);
        try self.showContextMenu(menu, MenuAnchor.mouse(event));
    }

    pub fn showTerminalTabListMenu(self: *Workbench, event: *const ui.MouseEvent) !void {
        const menu = try self.newContextMenu(onTerminalMenu);
        errdefer menu.deinit();
        try terminal_actions.appendTabListActions(self.terminalConfig(), menu);
        try self.showContextMenu(menu, MenuAnchor.mouse(event));
    }

    fn showTerminalRename(self: *Workbench, instance: *terminal_service_mod.TerminalInstance) !void {
        const service = self.terminal_service orelse return;
        try terminal_actions.showRenamePicker(service, self.quick_access.inputService(), instance);
    }

    pub fn terminalCount(self: *const Workbench) usize {
        const service = self.terminal_service orelse return 0;
        return service.instanceCount();
    }

    pub fn disposeExitedTerminal(self: *Workbench, instance: *terminal_service_mod.TerminalInstance) !void {
        const service = self.terminal_service orelse return;
        const exit = instance.exit orelse return;
        reportTerminalExit(exit);
        for (service.group.instances.items, 0..) |candidate, index| {
            if (candidate == instance) return self.killPanelTerminal(index);
        }
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.terminalInstance() == instance) return self.performCloseTab(pane, tab);
            }
        }
    }

    fn reportTerminalExit(exit: @import("../../platform/terminal/node/pty.zig").Exit) void {
        if (exit.code) |code| {
            if (code != 0) std.log.scoped(.terminal).warn("Terminal process exited with code {d}", .{code});
        }
        if (exit.signal) |number| std.log.scoped(.terminal).warn("Terminal process exited on signal {d}", .{number});
    }

    pub fn layoutAll(self: *Workbench) void {
        const override = if (self.layout.isZenModeActive()) self.zenModeConfiguration().show_tabs else null;
        self.part.handleChangedPartOptions(self.configuration, override);
        self.hovered_sash = null;
        self.layout.layoutTerminal(self.geometry());
        self.syncTerminalSize();
    }

    pub fn syncTerminalSize(self: *Workbench) void {
        const service = self.terminal_service orelse return;
        if (!self.terminalVisible()) return;
        self.terminal_tabbed_view.layoutInstances(self.geometry().panelRect(), service);
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
        if (pane.group.model.count() != 0 or self.service.count() <= 1) return;
        self.editor_drop_target.invalidateDragPane(pane);
        if (self.part.maximized_group == pane) self.part.setMaximizedGroup(null);
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
        return (editor_service_mod.EditorService{ .part = self.part }).tabCount();
    }

    pub fn groupCount(self: *const Workbench) usize {
        return self.service.count();
    }

    pub const OpenOptions = editor_service_mod.OpenOptions;

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

        const snippets = try features.completion_provider.register(.{ .language = "*" }, self.snippet_provider.interface());
        errdefer snippets.dispose();
        const words = try features.completion_provider.register(.{ .language = "*" }, word_provider.interface());
        errdefer words.dispose();
        const listener = try marker_service.on_marker_changed.listen(self, onMarkersChanged);
        errdefer marker_service.on_marker_changed.unlisten(listener);
        self.outline_creator = .{
            .models = try self.instantiation.invokeFunction(outline_model.getOutlineModelService, .{}),
            .features = features,
            .configuration = &self.configuration,
            .markers = marker_decorations,
        };
        errdefer self.outline_creator = null;
        try self.outline_creator.?.register(&self.outline_service);
        self.language_features = features;
        self.marker_service = marker_service;
        self.marker_decorations = marker_decorations;
        self.word_completion_provider = word_provider;
        self.snippet_registration = snippets;
        self.word_completion_registration = words;
        self.marker_listener = listener;
        if (self.markers_status) |status| status.attach(marker_service);
        if (self.problems_view) |*view| view.setService(marker_service);

        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                tab.editor.attachLanguageServices(features, marker_service, marker_decorations);
                tab.attachLanguageRegistry(features);
            }
        }
    }

    fn onMarkersChanged(_: MarkerChangeEvent, self: *Workbench) !void {
        try self.syncPanelContainerVisibility();
        if (self.outline_view) |view| view.refresh() catch {};
    }

    /// Applies declarative language/grammar contributions to the open tabs and
    /// to tabs opened later.
    pub fn setDeclarativeExtensions(self: *Workbench, registry: *const extensions_registry.Registry) void {
        if (self.declarative == registry) return;
        self.snippet_provider.setCatalog(registry);
        self.declarative = registry;
        if (self.ensureThemeService()) |service| service.setFileIconThemeRegistry(registry) else |_| {}
        self.applyExtensionDefaults(registry) catch {};
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| tab.editor.applyDeclarativeExtensions(registry) catch {};
        }
    }

    fn applyExtensionDefaults(self: *Workbench, catalog: *const extensions_registry.Registry) !void {
        const config = self.configuration orelse return;
        for (catalog.extensions) |extension| {
            if (extension.configuration_defaults) |defaults| {
                try configuration_extension_point.registerConfigurationDefaults(config.registry, defaults);
            }
        }
        try config.reload();
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
        if (self.declarative) |catalog| {
            for (catalog.extensions) |extension| {
                if (!std.ascii.eqlIgnoreCase(extension.id(), extension_id) or extension.configuration_defaults == null) continue;
                // Language overrides were already loaded from the installed manifest.
                if (manifest != .object) return;
                const points = manifest.object.get("contributes") orelse return;
                if (points != .object) return;
                const properties = points.object.get("configuration") orelse return;
                configuration_extension_point.registerConfigurationValue(config.registry, properties, extension_id) catch return;
                config.reload() catch {};
                return;
            }
        }
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

    pub fn configureJsonLanguage(self: *Workbench) void {
        const client = self.json_client orelse return;
        const config = self.configuration orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const schemas = self.jsonSchemasValue();
        const setting = config.getValue("json.maxItemsComputed", .{});
        const limit = if (setting) |value| switch (value.*) {
            .integer => value.integer,
            .float => if (value.float > 0 and value.float < @as(f64, @floatFromInt(std.math.maxInt(i64)))) @as(i64, @intFromFloat(value.float)) else 5000,
            else => 5000,
        } else 5000;
        client.configureWithLimit(arena.allocator(), if (schemas) |value| value.* else null, limit) catch {};
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

    // --- begin git / source control

    fn deinitGit(self: *Workbench) void {
        if (self.scm_container) |container| {
            self.sidebar_part.unregisterViewPaneContainer(container);
            self.view_descriptor_service.unregisterViewContainerModel(container.model);
            container.deinit();
            self.allocator.destroy(container);
            self.scm_container = null;
        }
        if (self.scm_view_model) |model| {
            model.deinit();
            self.allocator.destroy(model);
            self.scm_view_model = null;
        }
        self.scm.deinit();
        self.git_model.deinit();
    }

    /// Creates the git CLI/service, the SCM provider/view and the quick-diff
    /// controller for the workspace folder. A missing git binary, a disabled
    /// `git.enabled` or a non-repository leaves the editor untouched.
    pub fn initGit(self: *Workbench) !void {
        if (self.git_model.git != null) return;
        const root = self.workspaceFolderPath() orelse return;
        const provider = (try self.git_model.openRepository(root, .{
            .io = self.io,
            .configuration = self.configuration,
            .window = &self.window_events,
            .host = .{ .context = self, .open_change = providerOpenChange, .refresh = scmRefresh },
            .on_disabled = gitDisabled,
            .on_disabled_context = self,
        })) orelse return;
        errdefer self.deinitGit();
        const quick_providers = provider.quickDiffProviders();
        try self.scm.attachProvider(provider.interface(), &quick_providers, .{
            .editors = .{ .part = self.part },
            .activity_service = &self.activity_service,
            .statusbar_service = &self.statusbar,
            .window = &self.window_events,
            .configuration = self.configuration,
            .changes_host = .{
                .context = self,
                .open_change = scmViewOpen,
                .resource_action = scmViewResourceAction,
                .refresh = scmRefresh,
                .focus_editor = scmFocusEditor,
                .commit = scmViewCommit,
                .commit_menu = scmCommitMenu,
                .branch_action = scmBranchAction,
                .status = scmViewStatus,
            },
            .quick_input = self.quick_access.inputService(),
            .history_host = .{
                .context = self,
                .open_change = historyOpenChange,
                .open_changes = historyOpenChanges,
                .focus_editor = scmFocusEditor,
            },
        });
        self.scm.attachHistoryProvider(provider.interface(), self.theme_palette);

        const view_model = try self.allocator.create(view_container_model_mod.ViewContainerModel);
        view_model.* = view_container_model_mod.ViewContainerModel.init(self.allocator, .{
            .id = "scm",
            .title = "Source Control",
            .icon = "",
        });
        self.scm_view_model = view_model;
        const has_history = provider.historyProvider() != null;
        try addSidebarViewDescriptors(view_model, true, has_history);
        if (self.explorer_view_model) |model| {
            for (model.views.items) |*view| {
                if (std.mem.eql(u8, view.id, "changes")) view.available = true;
                if (std.mem.eql(u8, view.id, "graph")) view.available = has_history;
            }
        }
        view_model.setActiveView("changes");

        self.scm_container = try self.createSidebarContainer(
            view_model,
            self.explorer_panes.?,
        );

        if (self.file_watcher_service) |files_service| provider.watch(files_service) catch {};
    }

    /// Re-reads git status, the SCM rows, the quick-diff baselines, the
    /// branch/status entry and the activity badge.
    pub fn refreshGitStatus(self: *Workbench) void {
        const provider = self.git_model.repository orelse return;
        provider.refresh() catch {};
        if (provider.refreshHistoryRefs(true)) {
            if (self.scm.history) |view| view.onHistoryItemRefsChanged(true);
        }
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
        if (self.git_model.repository == null) return error.NoRepository;
        const left_label = left_ref.label();
        const right_label = right_ref.label();

        const working = if (left_ref == .working or right_ref == .working) if (self.findOpenInput(path)) |input| blk: {
            var value = try input.editor.model.getValue(.TextDefined, true);
            break :blk try value.toOwnedSlice();
        } else null else null;
        defer if (working) |text| self.allocator.free(text);
        const text = try self.git_model.resolveDiffTexts(path, working, left_ref, right_ref);
        defer self.allocator.free(text.original);
        defer self.allocator.free(text.modified);
        if (text.original.len == 0 and text.modified.len == 0 and (editor_service_mod.EditorService{ .part = self.part }).findDiffTab(path, left_label, right_label) == null) {
            const file_exists = if (std.Io.Dir.cwd().access(self.io, path, .{})) |_| true else |_| false;
            if (file_exists) {
                if (self.status_hint_accessor) |hint| {
                    hint.update(.{ .name = "Source Control", .text = "Diff skipped: binary or too large" });
                }
                return error.DiffUnavailable;
            }
        }

        try self.openSnapshotDiff(path, text.original, text.modified, left_label, right_label);
    }

    /// Opens a read-only diff between the parent revision and a history item.
    /// `original_path` is the rename source; `left_rev == null` compares the
    /// root commit against the empty tree.
    fn openRefDiff(
        self: *Workbench,
        path: []const u8,
        original_path: ?[]const u8,
        left_rev: ?[]const u8,
        right_rev: []const u8,
        left_label: []const u8,
        right_label: []const u8,
    ) !void {
        const texts = try self.git_model.resolveRefDiffTexts(path, original_path, left_rev, right_rev);
        defer self.allocator.free(texts.original);
        defer self.allocator.free(texts.modified);
        try self.openSnapshotDiff(path, texts.original, texts.modified, left_label, right_label);
    }

    fn openSnapshotDiff(
        self: *Workbench,
        path: []const u8,
        original_text: []const u8,
        modified_text: []const u8,
        left_label: []const u8,
        right_label: []const u8,
    ) !void {
        const editors = editor_service_mod.EditorService{ .part = self.part };
        try editors.openSnapshotDiff(self.view_factory, self.io, if (self.configuration) |config| config.interface() else null, path, original_text, modified_text, left_label, right_label);
        self.focusEditor();
    }

    fn openScmChange(self: *Workbench, provider: *repository_mod.Repository, resource: *repository_mod.GitScmResource) !void {
        if (provider.diffRefsForResource(resource)) |refs| {
            try self.openDiff(resource.absolute_path, refs.left, refs.right);
        } else try self.openPath(resource.absolute_path);
    }

    fn gitDisabled(context: ?*anyopaque, reason: []const u8) void {
        const raw_context = context orelse return;
        const self: *Workbench = @ptrCast(@alignCast(raw_context));
        self.setStatusHint("Source Control disabled: {s}", .{reason});
    }

    fn providerOpenChange(context: *anyopaque, provider: *repository_mod.Repository, resource: *repository_mod.GitScmResource) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return self.openScmChange(provider, resource);
    }

    fn scmOpenChange(context: *anyopaque, resource: *scm_common.ISCMResource) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const provider = self.git_model.repository orelse return;
        const git_resource = @as(*repository_mod.GitScmResource, @ptrCast(@alignCast(resource.context)));
        return self.openScmChange(provider, git_resource);
    }

    fn scmViewOpen(context: *anyopaque, resource: *scm_common.ISCMResource) anyerror!void {
        return scmOpenChange(context, resource);
    }

    fn scmViewResourceAction(context: *anyopaque, action: scm_view_mod.ResourceAction, resource: *scm_common.ISCMResource) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.runScmResourceAction(action, resource) catch |err| self.setStatusHint("Source Control action failed: {s}", .{@errorName(err)});
    }

    fn runScmResourceAction(self: *Workbench, action: scm_view_mod.ResourceAction, resource: *scm_common.ISCMResource) !void {
        const git_resource: *repository_mod.GitScmResource = @ptrCast(@alignCast(resource.context));
        const provider = git_resource.provider;
        switch (action) {
            .open_file => {
                if (git_resource.status == 'D') {
                    try self.openScmChange(provider, git_resource);
                } else {
                    try self.openPath(git_resource.absolute_path);
                    self.focusEditor();
                }
            },
            .open_change => try self.openScmChange(provider, git_resource),
            .stage, .unstage => {
                const git = provider.git orelse return error.NoGit;
                const head = provider.repository.stateRef().head;
                const has_head = if (head) |branch| branch.ref.commit != null else false;
                const operation: git_mod.Git.ResourceAction = if (action == .stage) .stage else if (has_head) .unstage else .unstage_unborn;
                var paths = [_][]const u8{ git_resource.relative_path, "" };
                var count: usize = 1;
                if (git_resource.status == 'R') {
                    if (git_resource.original_path) |path| {
                        paths[1] = path;
                        count += 1;
                    }
                }
                try git.runResourceAction(provider.root, operation, paths[0..count]);
                scmRefresh(self);
            },
            .discard => try self.confirmScmDiscard(git_resource),
        }
    }

    fn confirmScmDiscard(self: *Workbench, resource: *const repository_mod.GitScmResource) !void {
        if (self.isDialogOpen()) return error.DialogAlreadyOpen;
        if (resource.kind != .working and resource.kind != .untracked) return error.InvalidScmResource;
        const untracked = resource.kind == .untracked;
        const message = try std.fmt.allocPrint(self.allocator, "{s} {s}?", .{
            if (untracked) "Permanently delete the untracked file" else "Discard working tree changes to",
            resource.relative_path,
        });
        defer self.allocator.free(message);
        const root = try self.allocator.dupe(u8, resource.provider.root);
        errdefer self.allocator.free(root);
        const path = try self.allocator.dupe(u8, resource.relative_path);
        errdefer self.allocator.free(path);
        const pending = try self.allocator.create(ScmDiscardDialog);
        errdefer self.allocator.destroy(pending);
        pending.* = .{ .workbench = self, .request = .{ .root = root, .path = path, .untracked = untracked } };
        _ = try self.dialog_service.confirm(.{
            .message = message,
            .detail = if (untracked) "This deletes the file from disk." else "This restores the file from the Git index.",
            .primary_button = if (untracked) "Delete" else "Discard",
            .initial_focus = 1,
        }, .{ .context = pending, .complete = onScmDiscardConfirmed, .dispose = disposeScmDiscardDialog });
    }

    fn onScmDiscardConfirmed(context: *anyopaque, result: dialogs.IConfirmationResult) void {
        const pending: *ScmDiscardDialog = @ptrCast(@alignCast(context));
        if (result.confirmed) pending.workbench.resolveScmDiscard(pending.request) catch |err|
            pending.workbench.setStatusHint("Discard failed: {s}", .{@errorName(err)});
    }

    fn disposeScmDiscardDialog(context: *anyopaque) void {
        const pending: *ScmDiscardDialog = @ptrCast(@alignCast(context));
        const allocator = pending.workbench.allocator;
        pending.request.deinit(allocator);
        allocator.destroy(pending);
    }

    fn resolveScmDiscard(self: *Workbench, request: ScmDiscardRequest) !void {
        const provider = self.git_model.repository orelse return error.NoRepository;
        if (!std.mem.eql(u8, provider.root, request.root)) return error.RepositoryChanged;
        const git = provider.git orelse return error.NoGit;
        const absolute = try std.fs.path.join(self.allocator, &.{ request.root, request.path });
        defer self.allocator.free(absolute);
        defer scmRefresh(self);
        var state = try git.status(request.root);
        defer state.deinit(git.allocator);
        const candidates = if (request.untracked) state.untracked_changes else state.working_tree_changes;
        const change = for (candidates) |candidate| {
            if (std.mem.eql(u8, candidate.path, request.path)) break candidate;
        } else return error.ChangeNoLongerAvailable;
        if (request.untracked) {
            // A single-file unlink also refuses a directory that replaced the
            // file while the confirmation was open.
            try Io.Dir.cwd().deleteFile(self.io, absolute);
            self.requestFrame();
            return;
        }
        if (change.status == 'R' and change.original_path != null) {
            try git.runResourceAction(request.root, .restore, &.{ request.path, change.original_path.? });
            const original = try std.fs.path.join(self.allocator, &.{ request.root, change.original_path.? });
            defer self.allocator.free(original);
            self.handleFileChanges(&.{.{ .type = .UPDATED, .resource = original }});
        } else {
            try git.runResourceAction(request.root, .restore, &.{request.path});
        }
        self.handleFileChanges(&.{.{ .type = .UPDATED, .resource = absolute }});
    }

    fn scmRefresh(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.refreshGitStatus();
    }

    fn scmFocusEditor(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.focusEditor();
    }

    fn scmViewCommit(context: *anyopaque, message: []const u8, action: scm_view_mod.CommitAction) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        try (try self.gitCommands()).commit(message, action);
    }

    fn scmViewStatus(context: *anyopaque, message: []const u8) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.setStatusHint("{s}", .{message});
    }

    fn scmCommitMenu(context: *anyopaque, event: *const ui.MouseEvent) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const menu = try self.newContextMenu(runScmCommitAction);
        errdefer menu.deinit();
        try menu.add("commit", .{ .label = "Commit" });
        try menu.add("amend", .{ .label = "Commit (Amend)" });
        try menu.separator();
        try menu.add("push", .{ .label = "Commit & Push" });
        try menu.add("sync", .{ .label = "Commit & Sync" });
        try self.showContextMenu(menu, MenuAnchor.mouse(event));
    }

    fn runScmCommitAction(self: *Workbench, _: *MenuActionContext, id: []const u8) anyerror!void {
        const action = std.meta.stringToEnum(scm_view_mod.CommitAction, id) orelse return;
        if (self.scm.changes) |view| _ = view.commitInputWithAction(action);
    }

    fn scmBranchAction(context: *anyopaque, action: scm_view_mod.BranchAction) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        switch (action) {
            .publish => commandGitPublish(context) catch |err| self.setStatusHint("Publish failed: {s}", .{@errorName(err)}),
            .sync => {
                self.runScmRemoteAction(.pull, null) catch |err| {
                    self.setStatusHint("Pull failed: {s}", .{@errorName(err)});
                    return;
                };
                commandGitPush(context) catch {};
            },
        }
    }

    fn gitCommands(self: *Workbench) !@import("../../../extensions/git/src/commands.zig").Commands {
        return .{
            .allocator = self.allocator,
            .repository = self.git_model.repository orelse return error.NoRepository,
            .configuration = if (self.configuration) |config| config.interface() else null,
            .host = .{ .context = self, .report_status = scmViewStatus, .did_run_remote_action = onScmRemoteAction },
        };
    }

    fn runScmRemoteAction(self: *Workbench, action: git_mod.Git.RemoteAction, remote: ?[]const u8) !void {
        try (try self.gitCommands()).remote(action, remote);
    }

    fn onScmRemoteAction(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.refreshGitStatus();
        if (self.scm.history) |view| view.refresh(.reload) catch {};
    }

    fn scmChangesRenderBody(
        context: *anyopaque,
        grid: *ui.CellGrid,
        rect: ui.Rect,
        focused: bool,
    ) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm.changes orelse return;
        if (self.theme_palette) |palette| view.setThemeColors(palette);
        try view.render(grid, rect, focused, .{
            .show_header = false,
            .cell_borders = self.part.cell_borders,
            .border_capabilities = self.part.cell_border_capabilities,
        });
    }

    fn scmChangesHandleKey(context: *anyopaque, event: *ui.KeyEvent) anyerror!bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm.changes orelse return false;
        return view.handleKey(event);
    }

    fn scmChangesHandleMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) anyerror!bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm.changes orelse return false;
        return view.handleMouse(@constCast(event), rect);
    }

    fn scmChangesTitleActions(context: *anyopaque) []const views_mod.TitleAction {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm.changes orelse return &.{};
        return view.titleActions();
    }

    fn scmHistoryRenderBody(
        context: *anyopaque,
        grid: *ui.CellGrid,
        rect: ui.Rect,
        focused: bool,
    ) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm.history orelse return;
        if (self.theme_palette) |palette| view.setThemeColors(palette);
        try view.render(grid, rect, focused);
    }

    fn scmHistoryHandleKey(context: *anyopaque, event: *ui.KeyEvent) anyerror!bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm.history orelse return false;
        return view.handleKey(event);
    }

    fn scmHistoryHandleMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) anyerror!bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm.history orelse return false;
        return view.handleMouse(event, rect);
    }

    fn scmHistoryTitleActions(context: *anyopaque) []const views_mod.TitleAction {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm.history orelse return &.{};
        return view.titleActions();
    }

    fn historyOpenChange(
        context: *anyopaque,
        history_item: *const scm_common_history.ISCMHistoryItem,
        change: *const scm_common_history.ISCMHistoryItemChange,
    ) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const revision = if (self.scm.history) |view| view.itemRevision(history_item.*) else history_item.id;
        const display = if (std.mem.eql(u8, revision, history_item.id))
            history_item.display_id orelse history_item.id
        else
            revision[0..@min(revision.len, 7)];
        if (history_item.parent_ids.len > 0) {
            const parent = history_item.parent_ids[0];
            const parent_label = if (history_item.display_id) |id|
                parent[0..@min(parent.len, id.len)]
            else
                parent;
            return self.openRefDiff(
                change.path,
                change.original_path,
                parent,
                revision,
                parent_label,
                display,
            );
        }
        return self.openRefDiff(
            change.path,
            change.original_path,
            null,
            revision,
            "Empty",
            display,
        );
    }

    const HistoryChangesPick = struct {
        workbench: *Workbench,
        arena: std.heap.ArenaAllocator,
        item: scm_common_history.ISCMHistoryItem,
        changes: []scm_common_history.ISCMHistoryItemChange,
    };

    fn historyOpenChanges(
        context: *anyopaque,
        item: *const scm_common_history.ISCMHistoryItem,
        changes: []const scm_common_history.ISCMHistoryItemChange,
    ) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.showHistoryChanges(item, changes) catch |err| self.setStatusHint("Open Changes failed: {s}", .{@errorName(err)});
    }

    fn showHistoryChanges(self: *Workbench, item: *const scm_common_history.ISCMHistoryItem, changes: []const scm_common_history.ISCMHistoryItemChange) !void {
        if (changes.len == 0) {
            self.setStatusHint("No file changes in this history item", .{});
            return;
        }
        if (changes.len == 1) return historyOpenChange(self, item, &changes[0]);

        const state = try self.allocator.create(HistoryChangesPick);
        errdefer self.allocator.destroy(state);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const saved_changes = try allocator.alloc(scm_common_history.ISCMHistoryItemChange, changes.len);
        const items = try allocator.alloc(QuickPickItem, changes.len);
        for (changes, saved_changes, items, 0..) |change, *saved, *entry, index| {
            saved.* = try change.clone(allocator);
            entry.* = .{ .item = .{
                .id = try std.fmt.allocPrint(allocator, "{d}", .{index}),
                .label = std.fs.path.basename(saved.path),
                .description = std.fs.path.dirname(saved.path) orelse "",
            } };
        }
        var saved_item = try item.clone(allocator);
        if (self.scm.history) |view| {
            const revision = view.itemRevision(item.*);
            if (!std.mem.eql(u8, revision, item.id)) {
                saved_item.id = try allocator.dupe(u8, revision);
                saved_item.display_id = saved_item.id[0..@min(saved_item.id.len, 7)];
            }
        }
        state.* = .{ .workbench = self, .arena = arena, .item = saved_item, .changes = saved_changes };
        try self.quick_access.inputService().showPick(items, .{
            .placeholder = "Open Changes",
            .cleanup = freeHistoryChangesPick,
            .cleanup_context = state,
        }, onHistoryChangesPick, state);
    }

    fn freeHistoryChangesPick(context: *anyopaque) void {
        const state: *HistoryChangesPick = @ptrCast(@alignCast(context));
        const allocator = state.arena.child_allocator;
        state.arena.deinit();
        allocator.destroy(state);
    }

    fn onHistoryChangesPick(context: *anyopaque, picker: *QuickPick) anyerror!void {
        const state: *HistoryChangesPick = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse picker.activeItem() orelse return;
        const index = try std.fmt.parseInt(usize, item.id, 10);
        if (index < state.changes.len) try historyOpenChange(state.workbench, &state.item, &state.changes[index]);
    }

    const ShowTabs = layout_service_mod.EditorTabsMode;

    fn boolSetting(self: *Workbench, key: []const u8, default: bool) bool {
        const configuration = self.configuration orelse return default;
        return configuration.getBool(key, default);
    }

    fn pathForUri(allocator: Allocator, uri: []const u8) []const u8 {
        const parsed = std.Uri.parse(uri) catch return uri;
        if (!std.mem.eql(u8, parsed.scheme, "file")) return uri;
        return std_uri.fsPath(parsed, allocator) catch uri;
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
                if (!MarkdownPreviewConfig.eql(previous, config)) {
                    tab.refreshMarkdownPreview(true);
                }
            }
        }
    }

    pub fn toggleMarkdownPreview(self: *Workbench, pane: *GroupPane) !void {
        const tab = pane.activeTab() orelse return;
        if (tab.markdown_panel != null) return;
        if (!tab.isMarkdown()) {
            tab.editor.setMessage("Markdown preview is available for Markdown files only.", .{});
            return;
        }
        tab.setImageRuntime(&self.images);
        tab.setAsyncIo(self.async_io);
        try tab.toggleMarkdownEditor(self.markdownPreviewConfig(), self.theme_palette);
        pane.layout();
        self.focusEditor();
    }

    pub fn showMarkdownPreviewToSide(self: *Workbench) !void {
        return self.openMarkdownPanel(true);
    }

    fn onActiveMarkdownEditor(active_input: ?*EditorInput, self: *Workbench) anyerror!void {
        const input = active_input orelse return;
        if (!std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID)) return;
        const source: *FileEditorInput = @ptrCast(@alignCast(input.impl orelse return));
        if (!Tab.isMarkdownLanguage(source.editor.languageId())) return;
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.markdown_panel != null) try tab.updateMarkdownPanel(source);
            }
        }
    }

    pub fn openMarkdownPanel(self: *Workbench, beside: bool) !void {
        const pane = self.activePane() orelse return;
        const tab = pane.activeTab() orelse return;
        if (!tab.isMarkdown() or tab.markdown_preview != null) return;
        const source = tab.file_input orelse return;
        const direction = self.preferredSideBySideDirection();
        self.part.setMaximizedGroup(null);
        const adjacent = if (beside) try self.findAdjacentPane(direction, false) else pane;
        const target = adjacent orelse try self.part.splitGroup(pane, if (direction == .DOWN) .vertical else .horizontal, false);
        errdefer if (adjacent == null and target.isEmpty()) self.collapseEmptyPane(target);
        // An unlocked dynamic preview matches by destination group. Repeated
        // opens reveal the same panel even when the Markdown resource changes.
        for (target.tabs.items) |existing| {
            if (existing.markdown_panel == null) continue;
            try existing.updateMarkdownPanel(source);
            try target.activateTab(existing);
            try self.focusPane(target);
            return;
        }
        const preview = try Tab.initMarkdownPanel(self.view_factory, self.allocator, source, pane.group, self.markdownPreviewConfig(), self.theme_palette, &self.images, self.async_io, &self.window_events);
        {
            errdefer preview.deinit();
            try target.tabs.ensureUnusedCapacity(1);
            _ = try target.group.model.openEditor(preview.input, .{ .pinned = true, .active = true });
            try target.addTab(preview);
        }
        try self.focusPane(target);
    }

    pub fn showMarkdownSource(self: *Workbench) !void {
        const active = self.activeTab() orelse return;
        const panel = active.markdown_panel orelse {
            if (active.markdown_preview != null) try self.toggleMarkdownPreview(self.activePane().?);
            return;
        };
        const target = if (self.service.getGroup(panel.source_group)) |group| self.paneForGroup(group).? else self.activePane().?;
        if (target.group.model.findEditor(&panel.source.base, .{})) |match| {
            const source = target.tabForInput(match.editor) orelse return error.EditorNotFound;
            try target.activateTab(source);
            if (source.markdown_preview != null) try self.toggleMarkdownPreview(target);
        } else {
            // showTextDocument may reopen a source whose tab was closed.
            // Reuse the live document, including its unsaved text and undo.
            const input = try panel.source.copyInput();
            const source = Tab.initFromInput(self.view_factory, self.allocator, input) catch |err| {
                input.deinit();
                return err;
            };
            errdefer source.deinit();
            try target.tabs.ensureUnusedCapacity(1);
            _ = try target.group.model.openEditor(&input.base, .{ .active = true, .pinned = true });
            errdefer _ = target.group.model.closeEditor(&input.base, .UNKNOWN, true) catch {};
            try target.finishCopiedEditor(source, self.copyEditorHost());
        }
        try self.focusPane(target);
    }

    pub fn refreshMarkdownPreview(self: *Workbench) void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| tab.refreshMarkdownPreview(true);
        }
    }

    pub fn setSidebarViewStorage(self: *Workbench, user_data_dir: []const u8) !void {
        const state = try view_container_model_mod.ViewDescriptorsState.init(self.allocator, self.io, user_data_dir);
        if (self.view_state_storage) |old| old.deinit();
        self.view_state_storage = state;
        try self.restoreSidebarViewStates();
        self.updateSidebarTitleActions();
    }

    fn restoreSidebarViewStates(self: *Workbench) !void {
        const state = self.view_state_storage orelse return;
        try state.restore(self.workspace.getWorkspace().folders.items, &.{ self.explorer_view_model, self.scm_view_model });
    }

    fn saveSidebarViewStates(self: *Workbench) !void {
        const state = self.view_state_storage orelse return;
        try state.save(self.workspace.getWorkspace().folders.items, &.{ self.explorer_view_model, self.scm_view_model });
    }

    /// Snapshots the active editor's pane selection into the ported editor
    /// navigation history. Called before a jump or before an editor switch.
    pub fn recordNavigation(self: *Workbench) void {
        self.recordNavigationWithReason(.USER);
    }

    pub fn recordNavigationWithReason(self: *Workbench, reason: editor_mod.EditorPaneSelectionChangeReason) void {
        self.history.recordActiveNavigation(reason);
    }

    pub fn goBackInHistory(self: *Workbench) bool {
        return self.history.goBackInHistory();
    }

    pub fn goForwardInHistory(self: *Workbench) bool {
        return self.history.goForwardInHistory();
    }

    pub fn openPath(self: *Workbench, path: []const u8) !void {
        return self.openPathWithOptions(path, .{});
    }

    pub fn openPreviewPath(self: *Workbench, path: []const u8) !void {
        return self.openPathWithOptions(path, .{ .pinned = false });
    }

    fn samePath(self: *Workbench, left: []const u8, right: []const u8) bool {
        return text_files.samePath(self.allocator, self.io, left, right);
    }

    pub fn findOpenInput(self: *Workbench, path: []const u8) ?*FileEditorInput {
        return (editor_service_mod.EditorService{ .part = self.part }).findOpenFileInput(self.io, path);
    }

    pub fn findOpenImageInput(self: *Workbench, path: []const u8) ?*ImagePreviewEditorInput {
        return (editor_service_mod.EditorService{ .part = self.part }).findOpenImageInput(self.io, path);
    }

    fn openExistingImageInput(
        self: *Workbench,
        path: []const u8,
        existing: *ImagePreviewEditorInput,
        options: OpenOptions,
    ) !void {
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
            tab.setImageRuntime(&self.images);
            if (!options.preserve_focus) tab.focusEditor();
        }
        try self.history.add(path);
        self.pruneTabs(pane);
    }

    fn openImagePath(self: *Workbench, path: []const u8, options: OpenOptions, window: ?*@import("../../base/common/windowDispatch.zig").Queue) !void {
        const input = try ImagePreviewEditorInput.init(self.allocator, path);
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
                tab.setImageRuntime(&self.images);
                if (!options.preserve_focus) tab.focusEditor();
            }
            try self.history.add(path);
            self.pruneTabs(pane);
            return;
        }

        const tab = try Tab.initImageFromInput(self.view_factory, self.allocator, self.io, input, self.cols, self.editorContentHeight(), &self.images, window);
        try tab.view.setStatusBarVisible(false);
        try pane.addTab(tab);
        self.applyEditorSettingsToTab(tab);
        try pane.activateTab(tab);
        if (!options.preserve_focus) {
            self.focusEditor();
            tab.focusEditor();
        }
        try self.history.add(path);
        self.pruneTabs(pane);
    }

    fn openExistingInput(self: *Workbench, path: []const u8, existing: *FileEditorInput, options: OpenOptions) !void {
        const service = editor_service_mod.EditorService{ .part = self.part };
        try self.finishTextEditorOpen(path, try service.openExistingFileInput(existing, options), options);
    }

    fn openCreatedTextEditor(self: *Workbench, path: []const u8, editor: *Editor, options: OpenOptions) !void {
        self.applyConfiguredLanguageAssociations(editor);
        if (self.language_features) |features| editor.attachLanguageServices(features, self.marker_service, self.marker_decorations);
        const service = editor_service_mod.EditorService{ .part = self.part };
        try self.finishTextEditorOpen(path, try service.openTextEditor(self.view_factory, editor, options, &self.images), options);
    }

    fn finishTextEditorOpen(self: *Workbench, path: []const u8, opened: editor_service_mod.OpenedTextEditor, options: OpenOptions) !void {
        if (self.autoRevealEnabled(path)) {
            if (self.sidebar) |sidebar| sidebar.revealPath(path) catch {};
        }
        if (opened.tab) |tab| {
            tab.setImageRuntime(&self.images);
            if (opened.is_new) {
                self.applyEditorSettingsToTab(tab);
                self.registerWorkingCopy(tab);
            }
            if (self.language_features) |features| tab.attachLanguageRegistry(features);
            try tab.ensureControllers();
            if (!opened.is_new and !options.preserve_focus) tab.focusEditor();
        }
        try self.history.add(path);
        self.pruneTabs(opened.pane);
    }

    pub fn openPathWithOptions(self: *Workbench, path: []const u8, options: OpenOptions) !void {
        self.recordNavigation();
        if (!options.force_text and media_preview.opensInImagePreview(path)) {
            if (self.findOpenImageInput(path)) |existing| {
                return self.openExistingImageInput(path, existing, options);
            }
            return self.openImagePath(path, options, null);
        }
        if (self.findOpenInput(path)) |existing| {
            return self.openExistingInput(path, existing, options);
        }
        const size = (self.activePane() orelse return error.GroupPaneMissing).contentDimensions();
        const editor = try Editor.createWithExtensionsOptions(self.allocator, self.io, path, size.width, size.height, self.declarative, self.json_client, .{ .reserve_scrollbar = true });
        try self.openCreatedTextEditor(path, editor, options);
    }

    /// The Io used for interactive reads and network work. Callers pass this
    /// explicitly to `io.async`; it is deliberately separate from `io` so the
    /// async pool does not fall back to inline execution on the TUI thread.
    pub fn asyncIo(self: *const Workbench) Io {
        return self.async_io;
    }

    /// Interactive open: reads/decodes on the async Io and applies the result
    /// on read completion. The synchronous `openPath` remains for startup,
    /// session restore, tests and callers that already run off the TUI thread.
    pub fn requestOpenPath(self: *Workbench, path: []const u8) void {
        self.requestOpenPathWithOptions(path, .{});
    }

    pub fn requestOpenPathWithOptions(self: *Workbench, path: []const u8, options: OpenOptions) void {
        self.cancelPendingOpen();
        self.clearStatusHint();
        // Image tabs load their payload through `ImagePreviewPane.initAsync`;
        // constructing the tab itself does no file I/O.
        if (!options.force_text and media_preview.opensInImagePreview(path)) {
            if (self.findOpenImageInput(path)) |existing| {
                self.recordNavigation();
                self.openExistingImageInput(path, existing, options) catch |err| {
                    self.setStatusHint("Open failed: {s}", .{@errorName(err)});
                };
                return;
            }
            self.recordNavigation();
            self.openImagePath(path, options, &self.window_events) catch |err| {
                self.setStatusHint("Open failed: {s}", .{@errorName(err)});
            };
            return;
        }
        if (self.findOpenInput(path)) |existing| {
            self.recordNavigation();
            self.openExistingInput(path, existing, options) catch |err| {
                self.setStatusHint("Open failed: {s}", .{@errorName(err)});
            };
            return;
        }

        const read = TextFileRead.startWithListener(&self.text_file_service, path, true, .{ .context = self, .queue = &self.window_events, .run = openReadCompleted }) catch |err| {
            self.setStatusHint("Open failed: {s}", .{@errorName(err)});
            return;
        };
        self.pending_open = .{ .read = read, .options = options };
        self.setStatusHint("Opening {s}...", .{std.fs.path.basename(path)});
    }

    fn cancelPendingOpen(self: *Workbench) void {
        const job = self.pending_open orelse return;
        self.pending_open = null;
        job.read.cancel();
    }

    /// Starts one external-change reload per path. Results are applied by
    /// the completion handler after resolving the tab again.
    fn requestFileReload(self: *Workbench, path: []const u8) void {
        for (self.reload_jobs.items) |job| {
            if (self.samePath(job.path, path)) return;
        }
        const read = TextFileRead.startWithListener(&self.text_file_service, path, false, .{ .context = self, .queue = &self.window_events, .run = reloadCompleted }) catch return;
        self.reload_jobs.append(read) catch read.cancel();
    }

    fn reloadCompleted(context: *anyopaque, job: *TextFileRead) bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const index = std.mem.indexOfScalar(*TextFileRead, self.reload_jobs.items, job).?;
        _ = self.reload_jobs.swapRemove(index);
        defer job.destroy();
        var content = job.awaitResult() catch return false;
        defer content.deinit(self.allocator);
        const input = self.findOpenInput(job.path) orelse return false;
        if (input.editor.isDirty()) input.editor.markConflict() else input.editor.applyReloadedContent(content.text, content.encoding) catch {};
        return true;
    }

    fn cancelReloadJobs(self: *Workbench) void {
        for (self.reload_jobs.items) |job| job.cancel();
        self.reload_jobs.clearRetainingCapacity();
    }

    fn openLoadedTextEditor(self: *Workbench, path: []const u8, loaded: *const text_files.ResolvedTextFile, options: OpenOptions) !void {
        const size = (self.activePane() orelse return error.GroupPaneMissing).contentDimensions();
        const editor = try Editor.createWithExtensionsFromLoadedText(
            self.allocator,
            self.io,
            loaded,
            path,
            size.width,
            size.height,
            self.declarative,
            self.json_client,
            .{ .reserve_scrollbar = true },
        );
        try self.openCreatedTextEditor(path, editor, options);
    }

    /// Drains completed async reads on the TUI thread. Returns true when a
    /// result was applied and a repaint is needed.
    fn openReadCompleted(context: *anyopaque, read: *TextFileRead) bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const job = self.pending_open.?;
        std.debug.assert(job.read == read);
        self.pending_open = null;
        defer read.destroy();
        var loaded = read.awaitResult() catch |err| {
            self.setStatusHint("Open failed: {s}", .{@errorName(err)});
            return true;
        };
        defer loaded.deinit(self.allocator);
        self.recordNavigation();
        self.openLoadedTextEditor(read.path, &loaded, job.options) catch |err| {
            self.setStatusHint("Open failed: {s}", .{@errorName(err)});
            return true;
        };
        self.clearStatusHint();
        return true;
    }

    pub fn setStatusHint(self: *Workbench, comptime fmt: []const u8, args: anytype) void {
        const accessor = self.status_hint_accessor orelse return;
        const text = std.fmt.bufPrint(&self.status_hint_buf, fmt, args) catch return;
        accessor.update(.{ .name = "Source Control", .text = text });
    }

    fn clearStatusHint(self: *Workbench) void {
        if (self.status_hint_accessor) |accessor| {
            accessor.update(.{ .name = "Source Control", .text = "" });
        }
    }

    fn cancelAsyncJobs(self: *Workbench) void {
        self.cancelPendingOpen();
        self.cancelReloadJobs();
        if (self.theme_service) |service| service.cancelColorThemeLoad();
        self.user_keybindings.cancelReload();
        if (self.sidebar) |sidebar| sidebar.cancelLoad();
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.image_preview) |preview| preview.cancelLoad();
                if (tab.markdown_preview) |preview| preview.cancelImageJobs();
            }
        }
    }

    /// Replaces the active image preview tab with a text editor for the same
    /// file. This backs the message button and the
    /// `imagePreview.openInTextEditor` command (upstream exposes the same
    /// action as a button, and only as a command for SVG).
    pub fn openActiveImageAsText(self: *Workbench) !void {
        const pane = self.activePane() orelse return;
        const tab = pane.activeTab() orelse return;
        const input = tab.image_input orelse return;
        const path = try self.allocator.dupe(u8, input.path);
        defer self.allocator.free(path);
        const pinned = pane.group.model.isPinned(.{ .editor = tab.input });
        try self.openPathWithOptions(path, .{ .force_text = true, .pinned = pinned });
        try self.performCloseTab(pane, tab);
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

    pub fn runLspAction(self: *Workbench, id: []const u8) !bool {
        const action = go_to_commands.find(id) orelse return false;
        return self.executeSymbolNavigation(action);
    }

    pub fn executeSymbolNavigation(self: *Workbench, action: *const go_to_commands.ActionDescriptor) !bool {
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
        const links = try action.getLocationLinks(arena, features, model, position);

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
            const description = if (root) |value| @import("../../base/common/extpath.zig").relativeToRoot(path, value) orelse path else path;
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

        const providers = try features.document_symbol_provider.ordered(self.allocator, tab.editor.model, false);
        defer self.allocator.free(providers);
        if (providers.len == 0) {
            tab.editor.setMessage("{s}", .{goto_symbol_quick_access.no_provider_message});
            return false;
        }
        const input = self.quick_access.inputService();
        try input.showPick(&.{}, .{
            .placeholder = goto_symbol_quick_access.placeholder,
            .no_results_label = goto_symbol_quick_access.no_matching_message,
            .cleanup = cleanupSymbolPicker,
            .cleanup_context = self,
        }, onSymbolPick, self);
        input.pickerRef().setBusy(true);
        self.symbol_picker = .{ .tab = tab };
        errdefer input.hide();
        const subscription = try self.outline_creator.?.models.getOrCreate(tab.editor.model, providers, self, symbolPickerReady);
        if (self.symbol_picker) |*picker| picker.subscription = subscription;
        return self.symbol_picker != null;
    }

    fn cleanupSymbolPicker(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.closeSymbolPicker();
    }

    fn closeSymbolPicker(self: *Workbench) void {
        if (self.symbol_picker) |picker| {
            if (picker.subscription) |handle| handle.dispose();
            if (picker.outline) |outline| outline.deinit();
        }
        self.symbol_picker = null;
        self.pending_symbols = null;
    }

    fn symbolPickerReady(context: *anyopaque, outline: *OutlineModel) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const tab = if (self.symbol_picker) |picker| picker.tab else {
            outline.deinit();
            return;
        };
        self.symbol_picker.?.subscription = null;
        self.symbol_picker.?.outline = outline;
        const input = self.quick_access.inputService();
        if (self.activeTab() != tab) {
            input.hide();
            return;
        }
        input.pickerRef().setBusy(false);
        self.setSymbolItems(tab, outline) catch |err| {
            tab.editor.setMessage("Symbols failed: {s}", .{@errorName(err)});
            input.hide();
        };
    }

    fn setSymbolItems(self: *Workbench, tab: *Tab, outline: *OutlineModel) !void {
        const arena = self.navigation_arena.allocator();
        const entries = try goto_symbol_quick_access.collect(arena, outline);
        if (entries.len == 0) {
            tab.editor.setMessage("{s}", .{goto_symbol_quick_access.no_symbols_message});
            self.quick_access.inputService().hide();
            return;
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
        try self.quick_access.inputService().setPickItems(items.items, active_id);
    }

    /// Delivers a keydown to the editor contributions before the built-in
    /// extension key handlers run. Upstream's text area fires
    /// `CodeEditorWidget.onKeyDown` to the contributions before keybinding
    /// dispatch, so a Vim motion key must reach the hover first; otherwise a
    /// hover opened with `gh` never sees the motion that should dismiss it.
    ///
    /// Returns true when a focused editor widget (hover, find, suggest, sticky
    /// scroll) owns the keyboard. The extension handler must be skipped then so
    /// the key reaches that widget through the normal view dispatch.
    pub fn notifyEditorKeyDown(self: *Workbench, event: *ui.KeyEvent) bool {
        const tab = self.activeTab() orelse return false;
        if (tab.isDiff() or tab.isImage()) return false;
        tab.ensureControllers() catch return false;
        const controllers = tab.controllers orelse return false;
        _ = controllers.hover.onKeyDown(event);
        return !tab.view.hasEditorFocus();
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

            self.unregisterWorkingCopy(tab);
            self.history.detachHistoryTab(tab);
            self.detachTabViewHandlers(tab);
            tab.deinit();
        }
        if (removed_active) pane.syncActivePane();
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
        try tab.refresh();
        if (tab.terminal_input == null) {
            try self.history.add(tab.editor.path);
            self.revealActiveEditor();
        }
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
        self.part.setMaximizedGroup(null);
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

    fn findAdjacentPane(self: *Workbench, direction: editor_groups.GroupDirection, wrap: bool) !?*GroupPane {
        self.layoutAll();
        return self.part.findGroup(.{ .direction = direction }, self.activePane() orelse return null, wrap);
    }

    fn focusPane(_: *Workbench, pane: *GroupPane) !void {
        if (pane.activeTab()) |tab| try tab.ensureControllers();
        pane.focus();
    }

    fn onEditorGroupsChanged(self: *Workbench) !void {
        self.layoutAll();
        self.requestFrame();
    }

    fn onEditorPartFocus(_: void, self: *Workbench) !void {
        const pane = self.activePane() orelse return;
        pane.syncActivePane();
        self.layoutAll();
        if (pane.activeTab()) |tab| try tab.ensureControllers();
        self.focusEditor();
        self.revealActiveEditor();
    }

    /// `<C-w>h/j/k/l`: focus the nearest pane in a direction using the laid-out
    /// grid rectangles. This mirrors VS Code's directional group navigation
    /// without needing the browser grid's DOM geometry.
    pub fn navigateGroup(self: *Workbench, direction: GroupDirection) !void {
        const target = try self.findAdjacentPane(switch (direction) {
            .left => .LEFT,
            .right => .RIGHT,
            .up => .UP,
            .down => .DOWN,
        }, false) orelse return;
        self.service.activateGroup(target.group);
        if (target.activeTab() == null and target.tabs.items.len > 0) {
            try target.activateTab(target.tabs.items[0]);
        }
        target.syncActivePane();
        if (self.activeTab()) |tab| try tab.ensureControllers();
        self.revealActiveEditor();
    }

    /// Port of the `workbench.action.focus*Group` family. `wrap` matches
    /// upstream's focus actions, which wrap at the grid edge.
    pub fn focusGroupDirection(self: *Workbench, direction: editor_groups.GroupDirection) !void {
        const target = try self.findAdjacentPane(direction, true) orelse return;
        try self.focusPane(target);
    }

    pub fn focusGroupLocation(self: *Workbench, location: GroupLocation) !void {
        self.layoutAll();
        const source = self.activePane() orelse return;
        if (try self.part.findGroup(.{ .location = location }, source, true)) |view| try self.focusPane(view);
    }

    pub fn focusActiveGroup(self: *Workbench) !void {
        const pane = self.activePane() orelse return;
        try self.focusPane(pane);
    }

    /// Port of `workbench.action.newGroupLeft/Right/Above/Below`: add an empty
    /// group and activate it.
    pub fn newEmptyGroup(self: *Workbench, direction: editor_groups.GroupDirection) !*GroupPane {
        const source = self.activePane() orelse return error.NoActivePane;
        const view = try self.part.addGroup(source, direction);
        try self.focusPane(view);
        return view;
    }

    fn preferredOppositeDirection(self: *Workbench) editor_groups.GroupDirection {
        return if (self.preferredSideBySideDirection() == .RIGHT) .LEFT else .UP;
    }

    /// Resolves the target group for move/copy-editor commands. Directional
    /// commands create the missing group, matching `moveCopyEditorsToGroup`.
    fn resolveGroupTarget(
        self: *Workbench,
        source: *GroupPane,
        target: GroupTarget,
        create: bool,
    ) !?*GroupPane {
        switch (target) {
            .left, .right, .up, .down => {
                const direction: editor_groups.GroupDirection = switch (target) {
                    .left => .LEFT,
                    .right => .RIGHT,
                    .up => .UP,
                    else => .DOWN,
                };
                self.layoutAll();
                if (try self.part.findGroup(.{ .direction = direction }, source, false)) |pane| return pane;
                if (!create) return null;
                return try self.newEmptyGroup(direction);
            },
            .first, .last, .previous, .next => {
                const location: GroupLocation = switch (target) {
                    .first => .first,
                    .last => .last,
                    .previous => .previous,
                    .next => .next,
                    else => unreachable,
                };
                if (try self.part.findGroup(.{ .location = location }, source, false)) |view| return view;
                if (!create) return null;
                return try self.newEmptyGroup(if (location == .next) self.preferredSideBySideDirection() else self.preferredOppositeDirection());
            },
        }
    }

    /// Port of `workbench.action.closeGroup`: move the active group's editors
    /// into the most recently active other group, then remove the group.
    pub fn closeActiveGroup(self: *Workbench) !void {
        self.part.active_sash = null;
        const source = self.activePane() orelse return;
        if (self.groupCount() <= 1) return;
        const groups = try self.service.getGroups(self.allocator, .MOST_RECENTLY_ACTIVE);
        defer self.allocator.free(groups);
        var destination: ?*GroupPane = null;
        for (groups) |group| {
            if (group == source.group) continue;
            if (self.paneForGroup(group)) |pane| {
                destination = pane;
                break;
            }
        }
        const target = destination orelse return;
        try self.mergePaneInto(source, target);
    }

    /// Port of `workbench.action.joinTwoGroups`: merge the active group into
    /// the nearest neighbour, searching right, down, left then up.
    pub fn joinTwoGroups(self: *Workbench) !void {
        const source = self.activePane() orelse return;
        const directions = [_]editor_groups.GroupDirection{ .RIGHT, .DOWN, .LEFT, .UP };
        for (directions) |direction| {
            if (try self.findAdjacentPane(direction, false)) |target| {
                try self.mergePaneInto(source, target);
                return;
            }
        }
    }

    fn mergePaneInto(self: *Workbench, source: *GroupPane, target: *GroupPane) !void {
        if (source == target) return;
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try source.orderedTabs(self.allocator, &ordered);
        for (ordered.items) |tab| {
            try self.moveTabToPane(source, target, tab, null);
        }
        self.service.activateGroup(target.group);
        target.syncActivePane();
        if (source.tabs.items.len == 0) self.collapseEmptyPane(source);
        self.layoutAll();
        try self.focusPane(target);
    }

    fn destroyPane(self: *Workbench, pane: *GroupPane) void {
        self.editor_drop_target.invalidateDragPane(pane);
        while (pane.tabs.items.len > 0) {
            const tab = pane.tabs.items[0];
            _ = pane.group.model.closeEditor(tab.input, .UNKNOWN, true) catch {};
            _ = pane.removeTab(tab);
            self.discardTab(tab);
        }
        _ = self.part.removeView(pane);
    }

    /// Port of `workbench.action.duplicateActiveEditorGroupLeft/Right/Up/Down`:
    /// create a group beside the active one and copy every editor into it.
    pub fn duplicateActiveGroup(self: *Workbench, direction: editor_groups.GroupDirection) !void {
        self.part.setMaximizedGroup(null);
        self.part.active_sash = null;
        self.layoutAll();
        const source = self.activePane() orelse return;
        for (source.tabs.items) |tab| {
            if (tab.diff != null) return error.SplitUnsupported;
        }
        const orientation: SplitDirection = switch (direction) {
            .LEFT, .RIGHT => .horizontal,
            .UP, .DOWN => .vertical,
        };
        const target = try self.part.splitGroup(source, orientation, direction == .LEFT or direction == .UP);
        errdefer self.destroyPane(target);

        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try source.orderedTabs(self.allocator, &ordered);
        const active_index = source.activeIndex(ordered.items);
        var copies = std.array_list.Managed(*Tab).init(self.allocator);
        defer copies.deinit();
        for (ordered.items) |tab| {
            try copies.append(try self.copyTabIntoPane(target, tab));
        }
        if (copies.items.len > 0) {
            try target.activateTab(copies.items[@min(active_index, copies.items.len - 1)]);
        }
        try self.focusPane(target);
    }

    /// Port of `moveActiveEditor`/`copyActiveEditor` with `by: 'group'`, used
    /// by the moveEditorTo*Group and splitEditorTo*Group commands.
    pub fn moveOrSplitActiveEditor(self: *Workbench, target: GroupTarget, copy: bool) !void {
        self.layoutAll();
        const source = self.activePane() orelse return;
        const tab = source.activeTab() orelse return;
        const destination = try self.resolveGroupTarget(source, target, true) orelse return;
        if (destination == source) return;
        if (copy) {
            _ = try self.copyTabIntoPane(destination, tab);
        } else {
            try self.moveTabToPane(source, destination, tab, null);
            if (source.tabs.items.len == 0) self.collapseEmptyPane(source);
        }
        try self.focusPane(destination);
    }

    pub fn cycleGroup(self: *Workbench) !void {
        try self.focusGroupLocation(.next);
    }

    /// Port of `workbench.action.maximizeEditor`: expand the active group.
    pub fn maximizeActiveGroup(self: *Workbench) void {
        const pane = self.activePane() orelse return;
        if (self.part.maximized_group == pane) return;
        self.service.activateGroup(pane.group);
        pane.syncActivePane();
        self.part.setMaximizedGroup(pane);
        self.layoutAll();
        self.requestFrame();
    }

    pub fn minimizeActiveGroup(self: *Workbench) void {
        if (self.part.maximized_group == null) return;
        self.part.setMaximizedGroup(null);
        self.layoutAll();
        self.requestFrame();
    }

    pub fn closePanel(self: *Workbench) void {
        self.hidePanel();
    }

    /// Close every editor in every group, stopping at the first dirty-close
    /// confirmation instead of silently discarding the remaining editors.
    pub fn closeAllEditors(self: *Workbench) !void {
        self.history.beginClosedBatch();
        defer self.history.endClosedBatch();
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
        self.history.beginClosedBatch();
        defer self.history.endClosedBatch();
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
                const opened = try target.group.model.openEditor(tab.input, .{ .pinned = true, .active = false });
                if (!opened.is_new) {
                    // Target already shows this document (a split copy has a
                    // distinct input over the shared model); drop the moved view.
                    self.discardTab(tab);
                    continue;
                }
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

    /// Approximate the editor-part resize actions by changing the sidebar and
    /// panel sizes that determine the editor area.
    pub fn resizeEditorArea(self: *Workbench, width_delta: isize, height_delta: isize) !void {
        if (width_delta != 0 and self.geometry().sidebarShown()) {
            const current: isize = @intCast(self.geometry().sidebarWidth());
            try self.layout.setSize(.sidebar, self.geometry().clampSidebarWidth(@intCast(@max(current -| width_delta, 0))));
        }
        if (height_delta != 0 and self.geometry().panelShown()) {
            const current: isize = @intCast(self.geometry().panelHeight());
            const next: usize = @intCast(@max(current -| height_delta, 0));
            try self.layout.setSize(.panel, self.geometry().clampPanelHeight(next));
        }
        self.layoutAll();
    }

    pub fn showExplorer(self: *Workbench) !void {
        if (try self.showActivityById("explorer")) self.focusSidebar();
    }

    /// Preferred side-by-side split direction from
    /// `workbench.editor.openSideBySideDirection` (upstream
    /// `preferredSideBySideGroupDirection`).
    pub fn preferredSideBySideDirection(self: *Workbench) editor_groups.GroupDirection {
        return editor_groups.preferredSideBySideGroupDirection(if (self.configuration) |config| config.interface() else null);
    }

    /// Port of `workbench.action.splitEditor`: duplicate the active editor
    /// into a new group in the preferred side-by-side direction.
    pub fn splitActive(self: *Workbench, direction: SplitDirection) !void {
        try self.splitActiveInDirection(switch (direction) {
            .horizontal => .RIGHT,
            .vertical => .DOWN,
        });
    }

    /// Port of upstream `splitEditor(editorGroupsService, direction, context)`:
    /// create a group beside the active one and copy the active editor into it.
    /// The original tab stays open; both panes share the document/model and
    /// keep independent view state.
    pub fn splitActiveInDirection(self: *Workbench, direction: editor_groups.GroupDirection) !void {
        self.part.active_sash = null;
        self.part.setMaximizedGroup(null);
        self.editor_drop_target.clearTabDrag();
        const source = self.activePane() orelse return;
        const tab = source.activeTab() orelse return;

        const orientation: SplitDirection = switch (direction) {
            .LEFT, .RIGHT => .horizontal,
            .UP, .DOWN => .vertical,
        };
        const new_first = direction == .LEFT or direction == .UP;
        const new_pane = try self.part.splitGroup(source, orientation, new_first);
        var keep_view = false;
        defer {
            if (!keep_view) _ = self.part.removeView(new_pane);
        }

        const copied = try self.copyTabIntoPane(new_pane, tab);
        keep_view = true;

        self.layoutAll();
        if (self.activeTab()) |active| {
            try active.ensureControllers();
            try active.refresh();
            active.focusEditor();
        }
        self.focusEditor();
        _ = copied;
    }

    /// Copies `tab` into `target`, port of `EditorGroupView.copyEditor` plus
    /// the new editor pane the target group opens. File inputs share one
    /// `EditorDocument`; image previews get a new read-only pane.
    fn copyTabIntoPane(self: *Workbench, target: *GroupPane, tab: *Tab) !*Tab {
        return self.copyTabIntoPaneWithOptions(target, tab, .{ .pinned = true, .active = true });
    }

    fn copyTabIntoPaneWithOptions(self: *Workbench, target: *GroupPane, tab: *Tab, options: group_mod.EditorOpenOptions) !*Tab {
        return target.copyEditor(tab, options, self.copyEditorHost());
    }

    fn copyEditorHost(self: *Workbench) GroupPane.CopyEditorHost {
        return .{
            .context = self,
            .view_factory = self.view_factory,
            .io = self.io,
            .async_io = self.async_io,
            .images = &self.images,
            .window = &self.window_events,
            .configure = configureCopiedPane,
            .discard = discardTransferPane,
            .create_terminal = copyTerminalPane,
        };
    }

    fn configureCopiedPane(context: *anyopaque, tab: *Tab) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.applyEditorSettingsToTab(tab);
        if (!tab.isImage()) self.registerWorkingCopy(tab);
        if (self.language_features) |features| tab.attachLanguageRegistry(features);
    }

    fn copyTerminalPane(context: *anyopaque, target: *GroupPane, parent: *terminal_service_mod.TerminalInstance) !*Tab {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return self.createTerminalInEditor(target, parent);
    }

    pub fn closeActive(self: *Workbench) !bool {
        self.part.active_sash = null;
        self.editor_drop_target.clearTabDrag();
        const pane = self.activePane() orelse return false;
        // Upstream `workbench.action.closeActiveEditor` falls through to
        // `workbench.action.closeGroup` when the active group is empty.
        if (pane.tabs.items.len == 0) {
            try self.closeActiveGroup();
            return false;
        }
        const tab = pane.activeTab() orelse return false;
        return self.closeTab(pane, tab);
    }

    /// Closes the active tab without the dirty confirmation. `:q!` uses this;
    /// all other close paths keep the confirmation.
    pub fn forceCloseActive(self: *Workbench) !void {
        self.part.active_sash = null;
        self.editor_drop_target.clearTabDrag();
        const pane = self.activePane() orelse return;
        const tab = pane.activeTab() orelse return;
        try self.performCloseTab(pane, tab);
    }

    /// The group owns dirty-close confirmation; the host supplies disposal
    /// and focus at the terminal boundary.
    pub fn closeTab(self: *Workbench, pane: *GroupPane, tab: *Tab) !bool {
        if (self.isDialogOpen()) return false;
        try pane.handleCloseConfirmation(tab, self.dialog_api, self.closeEditorHost());
        return false;
    }

    pub fn closeEditorHost(self: *Workbench) GroupPane.CloseHost {
        return .{
            .context = self,
            .prepare_dialog = struct {
                fn run(context: *anyopaque) void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    host.part.active_sash = null;
                    host.editor_drop_target.clearTabDrag();
                    host.editor_drop_target.last_tab_click = null;
                }
            }.run,
            .focus_editor = struct {
                fn run(context: *anyopaque, tab: ?*Tab) void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    if (tab) |target| host.focusEditorAfterDialog(target) else host.focusActiveEditor();
                }
            }.run,
            .is_alive = struct {
                fn run(context: *anyopaque, pane: *GroupPane, tab: *Tab) bool {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    return host.paneExists(pane) and pane.indexOfTab(tab) != null;
                }
            }.run,
            .close_tab = struct {
                fn run(context: *anyopaque, pane: *GroupPane, tab: *Tab) !void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    try host.performCloseTab(pane, tab);
                }
            }.run,
            .report_error = struct {
                fn run(context: *anyopaque, err: anyerror) void {
                    const host: *Workbench = @ptrCast(@alignCast(context));
                    host.reportDialogError(err);
                }
            }.run,
        };
    }

    fn reportDialogError(self: *Workbench, err: anyerror) void {
        if (self.activeTab()) |tab| {
            tab.editor.setMessage("Close failed: {s}", .{@errorName(err)});
        }
        self.focusActiveEditor();
    }

    fn focusEditorAfterDialog(self: *Workbench, tab: *Tab) void {
        self.focusEditor();
        tab.focusEditor();
    }

    fn focusActiveEditor(self: *Workbench) void {
        self.focusEditor();
        if (self.activeTab()) |tab| tab.focusEditor();
    }

    pub fn reopenLastClosedEditor(self: *Workbench) bool {
        return self.history.reopenLastClosedEditor();
    }

    /// Detaches raw editor view-event handlers before a tab destroys its
    /// editor. Upstream disposes the outline/pane before the editor; the
    /// terminal keeps one shared OutlinePane, so it must let go of the editor
    /// while the editor is still alive.
    fn detachTabViewHandlers(self: *Workbench, tab: *Tab) void {
        if (self.outline_view) |view| {
            if (view.editor == tab.editor) view.setEditor(null) catch {};
        }
    }

    fn performCloseTab(self: *Workbench, pane: *GroupPane, tab: *Tab) !void {
        self.editor_drop_target.invalidateDragTab(pane, tab);
        if (self.context_menu_service.current) |menu| {
            if (menu.getActionsContext(MenuActionContext)) |context| {
                if (std.mem.indexOfScalar(*Tab, context.tabs, tab) != null) self.context_menu_service.hideContextMenu();
            }
        }
        self.history.recordClosedTab(pane, tab);
        _ = try pane.group.model.closeEditor(tab.input, .UNKNOWN, true);
        _ = pane.removeTab(tab);
        pane.syncActivePane();

        if (self.hovered_tab == tab) self.hovered_tab = null;
        if (!tab.isImage() and tab.terminal_input == null) {
            self.unregisterWorkingCopy(tab);
        }
        self.history.detachHistoryTab(tab);
        self.detachTabViewHandlers(tab);
        tab.deinit();

        if (self.tabCount() == 0) return;

        if (self.part.maximized_group == pane and pane.tabs.items.len == 0) self.part.setMaximizedGroup(null);

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
    pub fn toggleExpandGroup(self: *Workbench, pane: *GroupPane) void {
        if (self.part.maximized_group == pane) {
            self.part.setMaximizedGroup(null);
        } else {
            self.service.activateGroup(pane.group);
            pane.syncActivePane();
            self.part.setMaximizedGroup(pane);
        }
        self.layoutAll();
        self.requestFrame();
    }

    pub fn ensureContextKeys(self: *Workbench) !*context_key_mod.ContextKeyService {
        if (self.context_keys) |service| return service;
        const service = try self.allocator.create(context_key_mod.ContextKeyService);
        errdefer self.allocator.destroy(service);
        service.* = context_key_mod.ContextKeyService.init(self.allocator);
        errdefer service.deinit();
        try self.workbench_context.init(service.interface(), self.layout.interface(), &self.working_copy_service);
        errdefer self.workbench_context.deinit();
        try self.terminal_context.init(service.interface(), self.part, &self.panel_part, self.layout.interface());
        errdefer self.terminal_context.deinit();
        if (self.terminal_service) |terminal| try self.terminal_context.attach(terminal);
        self.context_key_handles = .{
            .editor_focus = try service.createKey("editorFocus", .{ .boolean = false }),
            .editor_lang_id = try service.createKey("editorLangId", .{ .string = "" }),
            .active_custom_editor_id = try service.createKey("activeCustomEditorId", .{ .string = "" }),
            .editor_text_focus = try service.createKey("editorTextFocus", .{ .boolean = false }),
            .input_focus = try service.createKey("inputFocus", .{ .boolean = false }),
            .list_focus = try service.createKey("listFocus", .{ .boolean = false }),
            .side_bar_focus = try service.createKey("sideBarFocus", .{ .boolean = false }),
            .status_bar_focus = try service.createKey("statusBarFocus", .{ .boolean = false }),
            .terminal_focus = try service.createKey("terminalFocus", .{ .boolean = false }),
            .panel_focus = try service.createKey("panelFocus", .{ .boolean = false }),
            .active_panel = try service.createKey("activePanel", .{ .string = "" }),
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
            .editor_read_only = try service.createKey("editorReadonly", .{ .boolean = false }),
            .legacy_editor_read_only = try service.createKey("editorReadOnly", .{ .boolean = false }),
        };
        self.context_keys = service;
        self.commands.context_keys = service.interface();
        self.updateContextKeys();
        return service;
    }

    pub fn updateContextKeys(self: *Workbench) void {
        const keys = self.context_key_handles orelse return;
        const active_activity = self.activity_bar_part.active_id orelse "";
        const sidebar_focused = self.focus == .sidebar and self.geometry().sidebarShown();
        const explorer_active = std.mem.eql(u8, active_activity, "explorer");
        const search_active = std.mem.eql(u8, active_activity, "search");
        const scm_active = std.mem.eql(u8, active_activity, "scm");
        const search_results_focused = if (self.search_view) |view| view.results_focused else false;
        const editor_focused = self.focus == .editor;
        keys.editor_focus.set(.{ .boolean = editor_focused });
        const active = self.activeTab();
        const terminal_editor_active = if (active) |tab| tab.terminal_input != null else false;
        const markdown_preview = if (active) |tab| tab.markdown_preview != null else false;
        const custom_preview = if (active) |tab| markdown_preview and tab.file_input != null else false;
        keys.editor_lang_id.set(.{ .string = if (active) |tab| (if (tab.file_input != null and !markdown_preview) tab.editor.languageId() else "") else "" });
        keys.active_custom_editor_id.set(.{ .string = if (custom_preview) "vscode.markdown.preview.editor" else "" });
        keys.editor_text_focus.set(.{ .boolean = editor_focused and !terminal_editor_active and !markdown_preview and !self.isDialogOpen() and !self.quick_access.isOpen() });
        keys.side_bar_focus.set(.{ .boolean = sidebar_focused });
        keys.list_focus.set(.{ .boolean = sidebar_focused and (!search_active or search_results_focused) });
        keys.input_focus.set(.{ .boolean = sidebar_focused and search_active and !search_results_focused });
        keys.status_bar_focus.set(.{ .boolean = self.focus == .statusbar });
        keys.terminal_focus.set(.{ .boolean = self.terminalFocused() });
        keys.panel_focus.set(.{ .boolean = (self.focus == .terminal or self.focus == .problems) and self.geometry().panelShown() });
        keys.active_panel.set(.{ .string = if (self.geometry().panelShown()) self.geometry().activePanelId() else "" });
        keys.in_quick_open.set(.{ .boolean = self.quick_access.isOpen() });
        keys.in_files_picker.set(.{ .boolean = self.quick_access.isOpen() and !self.quick_access.isPickOpen() });
        keys.explorer_viewlet_visible.set(.{ .boolean = self.geometry().sidebarShown() and explorer_active });
        keys.explorer_viewlet_focus.set(.{ .boolean = sidebar_focused and explorer_active });
        keys.files_explorer_focus.set(.{ .boolean = sidebar_focused and explorer_active });
        keys.search_viewlet_visible.set(.{ .boolean = self.geometry().sidebarShown() and search_active });
        keys.search_view_focus.set(.{ .boolean = sidebar_focused and search_active });
        keys.scm_viewlet_visible.set(.{ .boolean = self.geometry().sidebarShown() and scm_active });
        keys.scm_view_focus.set(.{ .boolean = sidebar_focused and scm_active });
        // Explorer file operations are not ported; these keys keep bindings
        // that require them inert rather than active.
        keys.explorer_resource_is_root.set(.{ .boolean = false });
        keys.explorer_resource_readonly.set(.{ .boolean = false });
        keys.tree_find_open.set(.{ .boolean = false });
        keys.resource_scheme.set(.{ .string = if (terminal_editor_active) "vscode-terminal" else "file" });
        const target = self.code_editor_api.getFocusedCodeEditor() orelse self.code_editor_api.getActiveCodeEditor();
        keys.editor_read_only.set(.{ .boolean = if (target) |editor| editor.isReadOnly() else false });
        keys.legacy_editor_read_only.set(.{ .boolean = if (self.activeTab()) |tab| tab.editor.read_only else false });
    }

    fn getFileIconTheme(self: *const Workbench) file_icon.FileIconThemeData {
        return if (self.theme_service) |service| service.getFileIconTheme() else .{};
    }

    pub fn themeColor(self: *const Workbench, id: []const u8, fallback: [3]u8) ui.Color {
        const palette = self.theme_palette orelse return .{ .r = fallback[0], .g = fallback[1], .b = fallback[2] };
        return palette.color(id, fallback);
    }

    fn userRemovalOverrides(self: *Workbench) []const *const resolved_keybinding_item.ResolvedKeybindingItem {
        return self.user_keybindings.removals();
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

    fn isKnownKeybindingCommand(context: *anyopaque, command: []const u8) bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return self.isKnownCommand(command);
    }

    fn onUserKeybindingsChanged(_: void, self: *Workbench) !void {
        self.disposeKeybindingServices();
        self.applyKeybindingConsumers();
        self.requestFrame();
    }

    fn disposeKeybindingServices(self: *Workbench) void {
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
    }

    fn applyKeybindingConsumers(self: *Workbench) void {
        const removals = self.userRemovalOverrides();
        for (self.part.group_views.items) |pane| {
            if (pane.watermark) |*watermark| watermark.invalidateShortcuts();
            for (pane.tabs.items) |tab| {
                if (!tab.isDiff()) tab.editor.reloadShortcutKeybindings(removals);
            }
        }
        if (self.search_view) |view| view.reloadKeybindings(removals);
    }

    fn ensureThemeService(self: *Workbench) !*theme_service_mod.ThemeService {
        if (self.theme_service) |service| return service;
        const service = try theme_service_mod.ThemeService.createDefault(self.allocator, null);
        errdefer service.deinit();
        service.attachWindow(.{ .io = self.async_io, .window = &self.window_events, .scheme = self.theme_scheme_host.interface() });
        service.setFileIconThemeRegistry(self.declarative);
        _ = try service.onDidColorThemeChange.listen(self, onColorThemeChanged);
        _ = try service.onDidFileIconThemeChange.listenSignal(self, onFileIconThemeChanged);
        self.theme_service = service;
        return service;
    }

    pub fn registerThemeSources(self: *Workbench, themes: []const extensions_registry.Theme) !void {
        try (try self.ensureThemeService()).registerThemeSources(themes);
    }

    pub fn applyThemeSettings(self: *Workbench) void {
        self.ensureConfiguration() catch {};
        const service = self.ensureThemeService() catch return;
        service.restoreColorTheme();
    }

    fn onFileIconThemeChanged(self: *Workbench) !void {
        self.requestFrame();
    }

    fn onColorThemeChanged(_: void, self: *Workbench) !void {
        const service = self.theme_service orelse return;
        self.refreshSyntaxTheme(true);
        const palette = try self.allocator.create(theme_colors_mod.ThemeColors);
        palette.* = theme_colors_mod.ThemeColors.init(service.getActiveTheme());
        const previous = self.theme_palette;
        self.theme_palette = palette;
        self.applyThemeToParts(palette);
        if (previous) |old| self.allocator.destroy(old);
        self.refreshOpenViews();
        self.requestFrame();
    }

    fn applyThemeToParts(self: *Workbench, palette: ?*const theme_colors_mod.ThemeColors) void {
        if (self.sidebar) |sidebar| sidebar.setThemeColors(palette);
        if (self.search_view) |view| view.setThemeColors(palette);
        if (self.scm.changes) |view| view.setThemeColors(palette);
        if (self.scm.history) |view| view.setThemeColors(palette);
        self.breadcrumbs.setThemeColors(palette);
        self.dialog_handler.setThemeColors(palette);
        self.statusbar.main_part.setThemeColors(palette);
        self.quick_access.setThemeColors(palette);
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.isDiff()) tab.view.setThemeColors(palette);
                if (tab.controllers) |controllers| controllers.setThemeColors(palette);
                if (tab.markdown_preview) |preview| preview.setThemeColors(palette);
                if (tab.image_preview) |image_pane| image_pane.setThemeColors(palette);
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

    pub fn ensureGlobalService(self: *Workbench) !*keybinding_service.KeybindingService {
        if (self.global_service) |service| return service;
        const context = try self.ensureContextKeys();
        self.updateContextKeys();
        const overrides = try self.user_keybindings.filteredOverrides(self, isKnownKeybindingCommand);
        defer self.allocator.free(overrides);
        const service = try keybinding_service.KeybindingService.initWithOptions(self.allocator, .{
            .rules = &global_keybinding_rules,
            .contributions = &self.commands.bindings,
            .executor = .{ .context = self, .execute = executeGlobalCommand },
            .context = context,
            .overrides = overrides,
        });
        self.global_service = service;
        return service;
    }

    pub fn ensureTabService(self: *Workbench) !*keybinding_service.KeybindingService {
        if (self.tab_service) |service| return service;
        self.user_keybindings.ensureLoaded() catch {};
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
            try self.focusGroupDirection(.LEFT);
            return .handled;
        }
        if (std.mem.eql(u8, command, "workbench.action.focusRightGroup")) {
            try self.focusGroupDirection(.RIGHT);
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

    pub fn requestQuit(self: *Workbench) bool {
        if (self.isDialogOpen()) return false;
        const CloseAllEditors = @import("parts/editor/editorActions.zig").CloseAllEditorsForWindow;
        if (!CloseAllEditors.hasDirtyEditors(self.part)) return true;
        CloseAllEditors.run(self.part, self.dialog_api, self.closeEditorHost(), onQuitAccepted) catch |err| {
            if (self.activeTab()) |tab| tab.editor.setMessage("Unable to open quit confirmation: {s}", .{@errorName(err)});
        };
        return false;
    }

    fn onQuitAccepted(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.quit_requested = true;
    }

    pub fn cancelSashDrag(self: *Workbench) bool {
        const grid = &self.layout.workbench_grid;
        var sidebar_drag = false;
        if (self.activeSidebarViewContainer()) |container| {
            sidebar_drag = container.header_press != null or container.sash_dragging != null or container.sash_hovered != null;
            container.cancelHeaderDrag();
            container.sash_dragging = null;
            container.sash_hovered = null;
        }
        if (!sidebar_drag and self.part.active_sash == null and grid.activeSash() == null and self.hovered_sash == null) return false;
        self.part.active_sash = null;
        grid.onSashEnd();
        self.hovered_sash = null;
        self.pointer = .default;
        return true;
    }

    /// Destroys a tab view that lost to an already-open editor, detaching the
    /// workbench registrations that keep raw pointers into it.
    fn discardTab(self: *Workbench, tab: *Tab) void {
        if (self.hovered_tab == tab) self.hovered_tab = null;
        self.history.detachHistoryTab(tab);
        self.unregisterWorkingCopy(tab);
        self.detachTabViewHandlers(tab);
        tab.deinit();
    }

    fn moveTabToPane(self: *Workbench, source: *GroupPane, dest: *GroupPane, tab: *Tab, index: ?isize) !void {
        _ = try self.moveTabToPaneWithOptions(source, dest, tab, .{ .pinned = true, .active = true, .index = index });
    }

    fn moveTabToPaneWithOptions(self: *Workbench, source: *GroupPane, dest: *GroupPane, tab: *Tab, options: group_mod.EditorOpenOptions) !*Tab {
        return source.moveEditor(dest, tab, options, .{ .context = self, .will_move = willMoveEditor, .discard = discardTransferPane, .focus_editor = focusEditorAfterTransfer });
    }

    fn willMoveEditor(context: *anyopaque, source: *GroupPane, tab: *Tab) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.editor_drop_target.invalidateDragTab(source, tab);
    }

    fn discardTransferPane(context: *anyopaque, tab: *Tab) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.discardTab(tab);
    }

    fn focusEditorAfterTransfer(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.setFocus(.editor);
    }

    /// A click on the leading ellipsis lists the tabs clipped out of the strip
    /// and activates the chosen one.
    pub fn showTabOverflowMenu(self: *Workbench, pane: *GroupPane, event: *const ui.MouseEvent) !bool {
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try pane.orderedTabs(self.allocator, &ordered);
        if (pane.hits.items.len >= ordered.items.len) return false;
        const menu = try self.newContextMenu(runTabOverflowAction);
        errdefer menu.deinit();
        const arena = menu.arena.allocator();

        var hidden = std.array_list.Managed(*Tab).init(arena);
        for (ordered.items, 0..) |tab, index| {
            var visible = false;
            for (pane.hits.items) |hit| {
                if (hit.index == index) {
                    visible = true;
                    break;
                }
            }
            if (!visible) try hidden.append(tab);
        }
        if (hidden.items.len == 0) {
            menu.deinit();
            return false;
        }

        for (hidden.items, 0..) |tab, index| {
            try menu.add(try std.fmt.allocPrint(arena, "overflow:{d}", .{index}), .{ .label = tab.input.getName() });
        }
        menu.getActionsContext(MenuActionContext).?.tabs = hidden.items;
        menu.getActionsContext(MenuActionContext).?.group_id = pane.group.id;
        try self.showContextMenu(menu, MenuAnchor.mouse(event));
        return true;
    }

    /// EditorTitleContext actions target the tab under the pointer.
    pub fn showTabContextMenu(self: *Workbench, pane: *GroupPane, tab: *Tab, event: *const ui.MouseEvent) !void {
        const menu = try self.newContextMenu(runTabMenuAction);
        errdefer menu.deinit();
        const arena = menu.arena.allocator();
        try menu.add("tab:close", .{ .label = "Close" });
        try menu.add("tab:close_others", .{ .label = "Close Others" });
        try menu.add("tab:close_right", .{ .label = "Close to the Right" });
        try menu.add("tab:close_saved", .{ .label = "Close Saved" });
        try menu.add("tab:close_all", .{ .label = "Close All" });
        try menu.separator();
        const pinned = pane.group.model.isPinned(.{ .editor = tab.input });
        try menu.add(if (pinned) "tab:unpin" else "tab:pin", .{ .label = if (pinned) "Unpin" else "Pin" });
        try menu.separator();
        try menu.add("tab:split_right", .{ .label = "Split Right" });
        try menu.add("tab:split_down", .{ .label = "Split Down" });
        if (tab.terminal_input != null) {
            try menu.add("tab:move_terminal_to_panel", .{ .label = "Move Terminal into Panel" });
            try menu.add("tab:rename_terminal", .{ .label = "Rename Terminal" });
        }
        menu.getActionsContext(MenuActionContext).?.group_id = pane.group.id;
        menu.getActionsContext(MenuActionContext).?.tabs = try arena.dupe(*Tab, &.{tab});
        try self.showContextMenu(menu, MenuAnchor.mouse(event));
    }

    /// Mirrors StatusbarPart.getContextMenuActions, including the empty row.
    pub fn showStatusbarContextMenu(self: *Workbench, handle: ?statusbar_model_mod.EntryHandle, event: *const ui.MouseEvent) !void {
        const menu = try self.newContextMenu(runTitleMenuAction);
        errdefer menu.deinit();
        try self.statusbar.main_part.getContextMenuActions(menu, handle, ToggleStatusbarVisibilityAction{ .workbench = self });
        try self.showContextMenu(menu, MenuAnchor.mouse(event));
    }

    pub fn ensureStatusbarService(self: *Workbench) !*keybinding_service.KeybindingService {
        if (self.statusbar_service) |service| return service;
        self.user_keybindings.ensureLoaded() catch {};
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
            part.clearHover();
            if (part.focusedHandle() != null) {
                part.clearFocus();
            } else {
                self.focusEditor();
            }
            return true;
        }
        return false;
    }

    pub fn clearStatusHover(self: *Workbench) void {
        self.statusbar.main_part.clearHover();
    }

    pub fn leaveEditorHover(self: *Workbench) void {
        if (self.activeTab()) |tab| {
            if (tab.controllers) |controllers| controllers.hover.hideContentHover();
        }
    }

    /// Clears the side bar view hover state: the Explorer row hover, the SCM
    /// pane header title action highlight and the Graph row hover. Called when
    /// pointer motion leaves the view content for the chrome or another part.
    pub fn clearSidebarViewHover(self: *Workbench) void {
        if (self.sidebar) |sidebar| sidebar.clearHover();
        if (self.search_view) |view| view.clearHover();
        if (self.scm_container) |container| container.clearHover();
        if (self.scm.changes) |view| view.clearHover();
        if (self.explorer_container) |container| container.clearHover();
        if (self.scm.history) |view| view.clearHover();
        if (self.outline_view) |view| view.clearHover();
    }

    pub fn activeSidebarViewContainer(self: *const Workbench) ?*view_pane_container_mod.ViewPaneContainer {
        const id = self.activity_bar_part.active_id orelse return null;
        return self.sidebar_part.getViewPaneContainer(id);
    }

    fn onViewContainerChanged(change: @import("../services/views/browser/viewDescriptorService.zig").ViewContainerChange, self: *Workbench) !void {
        const destination = self.sidebar_part.getViewPaneContainer(change.to.container.id) orelse return;
        _ = try self.showActivityById(change.to.container.id);
        destination.setActive(change.views[0]);
        self.updateSidebarTitleActions();
        try self.saveSidebarViewStates();
    }

    pub fn showSidebarViewMenu(
        self: *Workbench,
        container: *view_pane_container_mod.ViewPaneContainer,
        source: enum { header, container, overflow },
        header_id: ?[]const u8,
        anchor: MenuAnchor,
    ) !void {
        const model = container.model;
        const menu = try self.newContextMenu(runSidebarViewAction);
        errdefer menu.deinit();
        const arena = menu.arena.allocator();
        menu.getActionsContext(MenuActionContext).?.container_id = try arena.dupe(u8, model.container.id);
        const visible = try model.visibleViews(arena);
        const selected_id = header_id orelse if (visible.len == 1 and source != .overflow) visible[0].id else null;
        if (selected_id) |id| {
            for (visible) |view| {
                if (!std.mem.eql(u8, view.id, id)) continue;
                menu.getActionsContext(MenuActionContext).?.view_id = try arena.dupe(u8, view.id);
                const other = if (container == self.scm_container) self.explorer_container else self.scm_container;
                if (other != null and model.canMoveTo(view.id, other.?.model)) {
                    try menu.add("moveView", .{ .label = try std.fmt.allocPrint(arena, "Move View to {s}", .{other.?.model.container.title}) });
                }
                if (source == .header) {
                    try menu.add("hideView", .{
                        .label = try std.fmt.allocPrint(arena, "Hide '{s}'", .{view.name}),
                        .enabled = view.can_toggle_visibility and visible.len > 1,
                    });
                }
                if (menu.items.items.len != 0) try menu.separator();
                break;
            }
        }
        for (model.views.items) |view| {
            if (!view.in_container or !view.available) continue;
            try menu.add(try arena.dupe(u8, view.id), .{
                .label = view.name,
                .type = .checkbox,
                .checked = view.visible,
                .enabled = view.can_toggle_visibility and (!view.visible or visible.len > 1),
            });
        }
        if (source == .overflow) {
            // PaneComposite.getSecondaryActions flattens Views when it is the
            // only group, and combines it with a merged pane's secondary actions.
            const has_enabled = for (menu.items.items) |item| {
                if (item.enabled) break true;
            } else false;
            if (!has_enabled) menu.items.clearRetainingCapacity();
            if (visible.len == 1 and container.merge_view_with_container_when_single_view) {
                const pane_id = visible[0].id;
                const views = menu.items;
                menu.items = .empty;
                if (std.mem.eql(u8, pane_id, "changes")) {
                    if (self.scm.changes) |view| try scm_view_mod.appendSecondary(menu, &self.menu_service, (try self.ensureContextKeys()).interface().getContext(), view);
                } else if (std.mem.eql(u8, pane_id, "graph")) {
                    if (self.scm.history) |view| try scm_history_view_mod.appendSecondary(menu, &self.menu_service, (try self.ensureContextKeys()).interface().getContext(), view);
                } else if (std.mem.eql(u8, pane_id, "outline")) {
                    if (self.outline_view) |view| try @import("../contrib/outline/browser/outlineActions.zig").appendSecondary(menu, &self.menu_service, (try self.ensureContextKeys()).interface().getContext(), &view.view_state);
                }
                if (menu.items.items.len == 0) {
                    menu.items = views;
                } else if (views.items.len > 0) {
                    try menu.items.insertSlice(arena, 0, &.{
                        .{ .type = .submenu, .label = "Views", .submenu = views.items },
                        .{ .type = .separator },
                    });
                }
            }
        }
        if (menu.items.items.len == 0) {
            menu.deinit();
            return;
        }
        try self.showContextMenu(menu, anchor);
    }

    fn runSidebarViewAction(self: *Workbench, menu: *MenuActionContext, id: []const u8) anyerror!void {
        const container = self.sidebar_part.getViewPaneContainer(menu.container_id.?) orelse return;
        if (std.mem.eql(u8, id, "moveView")) {
            const other = if (container == self.scm_container) self.explorer_container else self.scm_container;
            if (other) |destination| _ = self.view_descriptor_service.moveViewsToContainer(&.{menu.view_id.?}, destination.model);
            return;
        }
        if (std.mem.eql(u8, id, "hideView")) {
            if (container.model.isVisible(menu.view_id.?)) container.model.toggleVisibility(menu.view_id.?);
        } else if (container.model.contains(id)) {
            container.model.toggleVisibility(id);
        } else return self.commands.execute(id);
        self.updateSidebarTitleActions();
    }

    pub fn clearTabHover(self: *Workbench) void {
        self.hovered_tab = null;
        self.hovered_pane = null;
        self.hovered_title_action_pane = null;
        if (self.breadcrumbs.activeControl()) |control| control.clearHover();
    }

    fn renderWatermarkShortcuts(context: *anyopaque, watermark: *editor_group_watermark.EditorGroupWatermark) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const service = try self.ensureGlobalService();
        var labels: [editor_group_watermark.entries.len]?[]const u8 = @splat(null);
        for (editor_group_watermark.entries, &labels) |entry, *label| {
            if (self.commands.get(entry.id) == null) continue;
            if (try service.service.lookupKeybinding(self.allocator, entry.id, false)) |binding| {
                label.* = binding.getLabel();
            }
        }
        try watermark.renderShortcuts(labels, self, executeWatermarkShortcut);
    }

    fn executeWatermarkShortcut(context: *anyopaque, id: []const u8) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.commands.execute(id) catch |err| std.log.warn("Editor shortcut {s} failed: {s}", .{ id, @errorName(err) });
    }

    fn renderWorkbench(self: *Workbench, parent: *ui.Node, options: IWorkbenchOptions) !void {
        const doc = parent.document;
        try editor_css.registerWorkbench(doc);
        const main = try doc.createElement(.div);
        self.layout.main_container = main;
        try main.addClass(editor_css.workbench.Class.monaco_workbench);
        try main.addClass(switch (@import("builtin").os.tag) {
            .windows => editor_css.workbench.Class.windows,
            .macos => editor_css.workbench.Class.mac,
            else => editor_css.workbench.Class.linux,
        });
        for (options.extra_classes) |class| try main.addClass(class);
        const Class = editor_css.part.Class;
        const side: Class = if (self.layout_api.getSideBarPosition() == .left) .left else .right;
        inline for (.{
            .{ .activitybar, "none", &[_]Class{ .activitybar, side } },
            .{ .sidebar, "none", &[_]Class{ .sidebar, side } },
            .{ .editor, "main", &[_]Class{.editor} },
            .{ .panel, "none", &[_]Class{ .panel, .basepanel, .bottom } },
            .{ .statusbar, "status", &[_]Class{.statusbar} },
        }) |description| {
            const container = try createPart(main, description[0], description[1], description[2]);
            const part = try self.layout.getPart(description[0]);
            try part.create(container);
        }
        _ = try parent.appendChild(main);
    }

    fn createPart(main: *ui.Node, comptime id: workbench_layout.Parts, role: []const u8, classes: []const editor_css.part.Class) !*ui.Node {
        const element = try main.document.createElement(if (id == .statusbar) .footer else .div);
        try element.setAttribute("id", "workbench.parts." ++ @tagName(id));
        try element.setAttribute("role", role);
        try element.addClass(editor_css.part.Class.part);
        for (classes) |class| try element.addClass(class);
        if (id == .statusbar) try element.setAttribute("aria-live", "off");
        _ = try main.appendChild(element);
        return element;
    }

    pub fn watermarkShortcuts(self: *Workbench) editor_group_view.WatermarkShortcuts {
        return .{ .context = self, .render = renderWatermarkShortcuts };
    }

    pub fn setFocus(self: *Workbench, focus: Focus) void {
        self.focus = focus;
        self.updatePartFocus() catch {};
    }

    fn onDialogStateChanged(self: *Workbench) !void {
        self.pointer = .default;
        self.updatePartFocus() catch {};
        self.requestFrame();
    }

    fn onTerminalListFocus(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.updatePartFocus() catch {};
    }

    fn updatePartFocus(self: *Workbench) !void {
        const blocked = self.isDialogOpen() or self.quick_access.isOpen();
        self.part.setEditorFocus(!blocked and self.focus == .editor);
        if (self.terminal_service) |service| {
            if (service.setFocusedInstance(if (blocked) null else self.focusedTerminal())) self.terminal_input.button_down = null;
        }
    }

    /// First workspace folder resource, or null for an empty workspace.
    fn workspaceRoot(self: *const Workbench) ?[]const u8 {
        const folders = self.workspace.getWorkspace().folders.items;
        if (folders.len == 0) return null;
        return folders[0].resource;
    }

    /// Port of the `workbench.activityBar.location` / `.autoHide` /
    /// `.compact` configuration listener: the side bar part decides where its
    /// composite bar lives and whether the activity bar is shown at all.
    fn applyLayoutSettings(self: *Workbench, change: ?configuration_mod.Change) void {
        const values = layout_service_mod.LayoutSettingsValues.load(self.configuration, self.workspaceRoot());
        if (change == null or @import("../../platform/configuration/common/configuration.zig").affectsConfiguration(change.?, layout_service_mod.LayoutSettings.status_bar_visible))
            self.layout.setStatusBarConfiguration(values.status_bar_visible) catch {};
        if (change == null or @import("../../platform/configuration/common/configuration.zig").affectsConfiguration(change.?, layout_service_mod.LayoutSettings.sidebar_position))
            self.layout.setSideBarPosition(values.sidebar_position) catch {};
        self.activity_bar_part.setCompact(values.activity_bar_compact) catch {};
        self.sidebar_part.setLayoutSettings(values) catch {};
        self.syncActivityBarVisibility() catch {};
        self.layoutAll();
    }

    /// Port of `SidebarPart.onDidChangeActivityBarLocation`: the rail is shown
    /// while the side bar does not host the composite bar. Zen mode hides the
    /// rail independently of the configured location.
    fn syncActivityBarVisibility(self: *Workbench) !void {
        const hidden_by_zen = self.layout.isZenModeActive() and self.zenModeConfiguration().hide_activity_bar;
        const show = !hidden_by_zen and self.sidebar_part.shouldShowActivityBar();
        try self.layout.setPartHidden(!show, .activitybar);
    }

    /// Port of `getZenModeConfiguration` in `layout.ts`.
    fn zenModeConfiguration(self: *Workbench) zen_mode_contribution.ZenModeConfiguration {
        return zen_mode_contribution.load(self.configuration, self.workspaceRoot());
    }

    pub fn toggleZenMode(self: *Workbench, skip_layout: bool, restoring: bool) !void {
        try self.layout.toggleZenMode(skip_layout, restoring);
    }

    fn readZenModeConfiguration(context: *anyopaque) zen_mode_contribution.ZenModeConfiguration {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return self.zenModeConfiguration();
    }

    fn centeredEditorOptions(context: *anyopaque) Layout.CenteredEditorOptions {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return .fromEditorPart(self.part, self.configuration);
    }

    fn configuredPartVisible(context: *anyopaque, part: layout_service_mod.Parts) bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return switch (part) {
            .activitybar => self.sidebar_part.shouldShowActivityBar(),
            else => self.layout.isVisible(part),
        };
    }

    fn applyZenLineNumbers(context: *anyopaque, hidden: bool) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.applyEditorSettingsToAllTabs();
        if (!hidden) self.restoreLineNumbersFromConfiguration();
    }

    fn focusedLayoutPart(context: *anyopaque) layout_service_mod.Parts {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return switch (self.focus) {
            .sidebar => .sidebar,
            .terminal, .problems => .panel,
            .statusbar => .statusbar,
            .breadcrumbs, .editor => .editor,
        };
    }

    fn focusLayoutPart(context: *anyopaque, part: layout_service_mod.Parts) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        switch (part) {
            .sidebar => if (self.geometry().sidebarShown()) self.focusSidebar() else self.focusEditor(),
            .panel => {
                if (self.problemsVisible()) {
                    self.setFocus(.problems);
                    self.updateProblemsHighlight();
                } else if (self.terminalVisible()) {
                    self.setFocus(.terminal);
                } else return self.focusEditor();
                self.statusbar.main_part.clearFocus();
                if (self.search_view) |view| view.blur();
            },
            .statusbar => if (self.geometry().statusBarVisible()) self.focusStatusBar() else self.focusEditor(),
            else => self.focusEditor(),
        }
    }

    pub fn ensureBreadcrumbsControl(self: *Workbench, pane: *GroupPane) !*BreadcrumbsControl {
        return self.breadcrumbs.getControl(pane) orelse error.NoActiveTab;
    }

    fn ensureOutlineView(self: *Workbench) !*OutlinePane {
        if (self.outline_view) |view| return view;
        const view = try OutlinePane.init(self.allocator, .{
            .context = self,
            .active_editor = outlineActiveEditor,
            .active_resource = outlineActiveResource,
            .current_position = outlineViewCurrentPosition,
            .request_render = requestWorkbenchFrame,
            .focus_editor = outlineFocusEditor,
            .is_symbol_visible = outlineSymbolVisible,
        }, &self.outline_service);
        view.setThemeColors(self.theme_palette);
        view.setBorderRendering(self.part.cell_borders);
        self.outline_view = view;
        return view;
    }

    fn syncOutlineView(self: *Workbench) !void {
        const tab = self.activeTab();
        const editor: ?*Editor = if (tab) |active| blk: {
            if (active.isImage() or active.isDiff()) break :blk null;
            break :blk active.editor;
        } else null;
        const view = try self.ensureOutlineView();
        view.setThemeColors(self.theme_palette);
        view.setBorderRendering(self.part.cell_borders);
        if (view.editor != editor) try view.setEditor(editor);
    }

    pub fn requestFrame(self: *Workbench) void {
        if (self.frame_scheduler) |scheduler| scheduler.request(scheduler.context);
    }

    pub fn focusBreadcrumbs(self: *Workbench, select: bool) bool {
        const pane = self.activePane() orelse return false;
        const control = self.ensureBreadcrumbsControl(pane) catch return false;
        self.setFocus(.breadcrumbs);
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
        self.requestFrame();
        return true;
    }

    /// Opens the anchored file picker for `file`. Upstream
    /// `BreadcrumbsFilePicker` sets the tree input to the workspace for a root
    /// folder and to the clicked element's parent directory otherwise.
    pub fn showBreadcrumbPicker(self: *Workbench, file: *const breadcrumbs_model.FileElement, anchor: BreadcrumbsAnchor) !void {
        if (self.breadcrumb_popup) |popup| popup.close();
        _ = self.breadcrumbs_arena.reset(.retain_capacity);
        const arena = self.breadcrumbs_arena.allocator();
        const anchor_y = self.breadcrumbAnchorY();
        const picker = try self.ensureBreadcrumbPopup();

        if (file.kind == .ROOT_FOLDER) {
            const workspace = self.workspace.getWorkspace();
            var folders = std.array_list.Managed(breadcrumbs_picker.FolderRef).init(arena);
            for (workspace.folders.items) |folder| {
                try folders.append(.{ .path = folder.resource, .name = folder.name });
            }
            try picker.showFileWorkspace(folders.items, file.path, pickerAnchor(anchor), anchor_y);
        } else {
            const directory = breadcrumbs_picker.inputDirectory(file);
            try picker.showFileDirectory(directory, file.path, pickerAnchor(anchor), anchor_y);
        }
        self.requestFrame();
    }

    /// Upstream `BreadcrumbsOutlinePicker`: input the outline tree and reveal
    /// the clicked element.
    pub fn showBreadcrumbOutlinePicker(
        self: *Workbench,
        outline: *outline_mod.IOutline,
        element: *anyopaque,
        anchor: BreadcrumbsAnchor,
    ) !void {
        if (self.breadcrumb_popup) |popup| popup.close();
        _ = self.breadcrumbs_arena.reset(.retain_capacity);
        const picker = try self.ensureBreadcrumbPopup();
        try picker.showOutline(outline, element, pickerAnchor(anchor), self.breadcrumbAnchorY());
        self.requestFrame();
    }

    fn pickerAnchor(anchor: BreadcrumbsAnchor) breadcrumbs_picker.Anchor {
        return .{
            .start = anchor.start,
            .end = anchor.end,
            .cursor = anchor.cursor,
        };
    }

    fn breadcrumbAnchorY(self: *Workbench) usize {
        const pane = self.activePane() orelse return 0;
        return ui.cell.snap(pane.rect.y) + pane.titleHeight();
    }

    fn ensureBreadcrumbPopup(self: *Workbench) !*breadcrumbs_picker.Picker {
        if (self.breadcrumb_popup) |popup| {
            popup.setThemeColors(self.theme_palette);
            return popup;
        }
        const popup = try breadcrumbs_picker.Picker.init(
            self.allocator,
            .{
                .context = self,
                .io = self.io,
                .arena = self.breadcrumbs_arena.allocator(),
                .open_file = onBreadcrumbPickerOpenFile,
                .file_icon = onBreadcrumbPickerFileIcon,
                .request_render = requestWorkbenchFrame,
            },
            .{
                .context = self,
                .arena = self.breadcrumbs_arena.allocator(),
                .reveal = onBreadcrumbPickerReveal,
                .request_render = requestWorkbenchFrame,
            },
        );
        popup.setThemeColors(self.theme_palette);
        self.breadcrumb_popup = popup;
        return popup;
    }

    pub fn breadcrumbPopupVisible(self: *const Workbench) bool {
        const popup = self.breadcrumb_popup orelse return false;
        return popup.isVisible();
    }

    fn openBreadcrumbFile(self: *Workbench, path: []const u8) !void {
        self.requestOpenPath(path);
        self.focusEditor();
    }

    fn revealBreadcrumbElement(self: *Workbench, outline: *outline_mod.IOutline, element: *anyopaque) !void {
        try outline.reveal(element, .{});
        self.focusEditor();
    }

    pub fn resize(self: *Workbench, cols: usize, rows: usize) !void {
        _ = self.cancelSashDrag();
        self.editor_drop_target.clearTabDrag();
        self.terminal_tabbed_view.tab_list.dragging_sash = false;
        self.terminal_tabbed_view.tab_list.dragging_pane_sash = null;
        self.terminal_tabbed_view.tab_list.dragged_instance = null;
        self.terminal_tabbed_view.tab_list.drag_target = null;
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
        if (self.outline_view) |view| view.setBorderRendering(enabled);
        if (self.part.cell_borders == enabled) return;
        self.part.setCellBorders(enabled);
        if (self.geometry().sidebarShown() or self.geometry().panelShown() or self.part.maximized_group != null) self.layoutAll();
    }

    pub fn setCellBorderCapabilities(self: *Workbench, capabilities: ?ui.cell_border.Capabilities) void {
        self.part.cell_border_capabilities = capabilities orelse .{};
        self.setCellBorders(capabilities != null);
    }

    /// Hosts enable OSC 22 emission. Unlike borders and images the TUI does
    /// not probe: a pointer shape is out-of-band terminal state, so terminals
    /// without support ignore the sequence and nothing in the frame changes.
    pub fn setPointerShapes(self: *Workbench, enabled: bool) void {
        self.pointer_shapes = enabled;
    }

    /// The shape the next frame requests; the renderer diffs it against the
    /// shape already written to the terminal.
    pub fn setPointer(self: *Workbench, shape: ui.Pointer) void {
        self.pointer = shape;
    }

    pub fn pointerShape(self: *const Workbench) ui.Pointer {
        return self.pointer;
    }
};

fn explorerPaneRenderBody(context: *anyopaque, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) !void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const sidebar = self.sidebar orelse return;
    if (self.theme_palette) |palette| sidebar.setThemeColors(palette);
    try sidebar.render(grid, rect, focused, .{
        .show_header = false,
        .cell_borders = self.part.cell_borders,
    });
}

fn explorerPaneHandleKey(context: *anyopaque, event: *ui.KeyEvent) !bool {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const sidebar = self.sidebar orelse return false;
    switch (try sidebar.handleKey(event)) {
        .open => |path| {
            self.requestOpenPath(path);
            self.setFocus(.editor);
            return true;
        },
        .handled, .none => return true,
    }
}

fn explorerPaneHandleMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) !bool {
    _ = rect;
    const self: *Workbench = @ptrCast(@alignCast(context));
    const sidebar = self.sidebar orelse return false;
    return sidebar.handleMouse(event);
}

fn runPaneTitleAction(context: *anyopaque, id: []const u8) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.runSidebarTitleAction(id, null);
}

fn explorerPaneTitleActions(_: *anyopaque) []const views_mod.TitleAction {
    return &.{};
}

fn outlinePaneRenderBody(context: *anyopaque, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) !void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.syncOutlineView() catch {};
    if (self.outline_view) |view| {
        view.setThemeColors(self.theme_palette);
        try view.render(grid, rect, focused);
    }
}

fn outlinePaneHandleKey(context: *anyopaque, event: *ui.KeyEvent) !bool {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.syncOutlineView() catch {};
    if (self.outline_view) |view| return view.handleKey(event);
    return false;
}

fn outlinePaneHandleMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) !bool {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.syncOutlineView() catch {};
    if (self.outline_view) |view| return view.handleMouse(event, rect);
    return false;
}

fn outlinePaneTitleActions(context: *anyopaque) []const views_mod.TitleAction {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.syncOutlineView() catch return &.{};
    if (self.outline_view) |view| return view.titleActions();
    return &.{};
}

fn outlineActiveEditor(context: *anyopaque) ?OutlineEditor {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return null;
    if (tab.isImage() or tab.markdown_panel != null or tab.terminal_input != null) return null;
    return .{
        .context = @ptrCast(tab),
        .control = tab.editor,
        .resource = tab.editor.path,
        .language_id = tab.editor.languageId(),
    };
}

fn outlineActiveResource(context: *anyopaque) ?[]const u8 {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return null;
    return tab.editor.path;
}

fn outlineViewCurrentPosition(context: *anyopaque) ?Position {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return null;
    return tab.editor.modelSelection().getStartPosition();
}

fn requestWorkbenchFrame(context: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.requestFrame();
}

fn outlineFocusEditor(context: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.focusEditor();
    if (self.activeTab()) |tab| tab.focusEditor();
}

fn outlineSymbolVisible(context: *anyopaque, kind: u32) bool {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.boolSetting(outline_contrib.showConfigForKind(kind), true);
}

fn breadcrumbOpenElement(context: *anyopaque, selection: BreadcrumbsSelection, mode: BreadcrumbsSelectMode, anchor: BreadcrumbsAnchor) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    switch (selection) {
        .file => |file| {
            if (mode == .reveal and file.kind == .FILE) {
                try self.openBreadcrumbFile(file.path);
            } else {
                try self.showBreadcrumbPicker(file, anchor);
            }
        },
        .outline => |outline| {
            if (mode == .pick) {
                try self.showBreadcrumbOutlinePicker(outline.outline, outline.element, anchor);
            } else {
                try self.revealBreadcrumbElement(outline.outline, outline.element);
            }
        },
        .placeholder => {},
    }
}

fn breadcrumbRevealElement(context: *anyopaque, outline: *outline_mod.IOutline, element: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.revealBreadcrumbElement(outline, element);
}

fn breadcrumbFocusEditor(context: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.focusEditor();
    if (self.activeTab()) |tab| tab.focusEditor();
}

fn runActivityOverflowAction(self: *Workbench, _: *MenuActionContext, id: []const u8) anyerror!void {
    if (!std.mem.startsWith(u8, id, "activity:")) return;
    _ = try self.showActivityById(id[9..]);
}

fn runTabOverflowAction(self: *Workbench, menu: *MenuActionContext, id: []const u8) anyerror!void {
    const index = itemIndex(id, "overflow:") orelse return;
    const tabs = menu.tabs;
    if (index >= tabs.len) return;
    const group = self.service.getGroup(menu.group_id.?) orelse return;
    const pane = self.paneForGroup(group) orelse return;
    if (pane.indexOfTab(tabs[index]) == null) return;
    try pane.activateTab(tabs[index]);
    self.focusEditor();
    self.layoutAll();
}

fn runTabMenuAction(self: *Workbench, menu: *MenuActionContext, id: []const u8) anyerror!void {
    const group = self.service.getGroup(menu.group_id.?) orelse return;
    const pane = self.paneForGroup(group) orelse return;
    const tab = menu.tabs[0];
    if (pane.indexOfTab(tab) == null) return;

    if (std.mem.eql(u8, id, "tab:close")) {
        _ = try self.closeTab(pane, tab);
    } else if (std.mem.eql(u8, id, "tab:rename_terminal")) {
        if (tab.terminalInstance()) |instance| try self.showTerminalRename(instance);
    } else if (std.mem.eql(u8, id, "tab:move_terminal_to_panel")) {
        try self.moveTerminalToPanel(pane, tab);
    } else if (std.mem.eql(u8, id, "tab:close_others")) {
        const tabs = try self.allocator.dupe(*Tab, pane.tabs.items);
        defer self.allocator.free(tabs);
        for (tabs) |candidate| {
            if (candidate == tab) continue;
            _ = try self.closeTab(pane, candidate);
            if (self.isDialogOpen()) break;
        }
    } else if (std.mem.eql(u8, id, "tab:close_right")) {
        const index = pane.indexOfTab(tab) orelse return;
        const tabs = try self.allocator.dupe(*Tab, pane.tabs.items);
        defer self.allocator.free(tabs);
        for (tabs, 0..) |candidate, candidate_index| {
            if (candidate_index <= index) continue;
            _ = try self.closeTab(pane, candidate);
            if (self.isDialogOpen()) break;
        }
    } else if (std.mem.eql(u8, id, "tab:close_saved")) {
        const tabs = try self.allocator.dupe(*Tab, pane.tabs.items);
        defer self.allocator.free(tabs);
        for (tabs) |candidate| {
            if (candidate.editor.isDirty()) continue;
            _ = try self.closeTab(pane, candidate);
            if (self.isDialogOpen()) break;
        }
    } else if (std.mem.eql(u8, id, "tab:close_all")) {
        const tabs = try self.allocator.dupe(*Tab, pane.tabs.items);
        defer self.allocator.free(tabs);
        for (tabs) |candidate| {
            _ = try self.closeTab(pane, candidate);
            if (self.isDialogOpen()) break;
        }
    } else if (std.mem.eql(u8, id, "tab:pin")) {
        _ = pane.group.model.pin(tab.input) catch {};
        self.layoutAll();
    } else if (std.mem.eql(u8, id, "tab:unpin")) {
        _ = pane.group.model.unpin(tab.input) catch {};
        self.layoutAll();
    } else if (std.mem.eql(u8, id, "tab:split_right") or
        std.mem.eql(u8, id, "tab:split_down"))
    {
        try pane.activateTab(tab);
        self.focusEditor();
        try self.splitActive(if (std.mem.eql(u8, id, "tab:split_right"))
            .horizontal
        else
            .vertical);
    }
    self.requestFrame();
}

const ToggleStatusbarVisibilityAction = struct {
    workbench: *Workbench,

    pub fn run(self: *@This()) !void {
        const visible = self.workbench.layout.isVisible(.statusbar);
        try self.workbench.setUserConfigurationValue(layout_service_mod.LayoutSettings.status_bar_visible, .{ .bool = !visible });
        if (!self.workbench.geometry().statusBarVisible() and self.workbench.focus == .statusbar) self.workbench.focusEditor();
    }
};

fn onBreadcrumbPickerOpenFile(context: *anyopaque, path: []const u8) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.openBreadcrumbFile(path);
}

fn onBreadcrumbPickerFileIcon(context: *anyopaque, path: []const u8) file_icon.Icon {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.getFileIconTheme().forFile(std.fs.path.basename(path), null);
}

fn onBreadcrumbPickerReveal(context: *anyopaque, outline: *outline_mod.IOutline, element: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.revealBreadcrumbElement(outline, element);
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
    if (self.symbol_picker == null or self.symbol_picker.?.tab != tab) return;
    tab.editor.setSelection(entries[index].symbol.symbol.selection_range) catch |err| {
        tab.editor.setMessage("Navigation failed: {s}", .{@errorName(err)});
        return;
    };
    self.focusEditor();
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
    self.requestOpenPath(path);
}

fn quickOpenToSide(context: *anyopaque, path: []const u8) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const direction = self.preferredSideBySideDirection();
    const target = try self.findAdjacentPane(direction, false) orelse try self.newEmptyGroup(direction);
    for (self.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| {
            const resource = if (tab.file_input) |input| input.editor.path else tab.imagePath() orelse continue;
            if (!self.samePath(resource, path)) continue;
            const copy = if (pane == target) tab else try self.copyTabIntoPane(target, tab);
            try target.activateTab(copy);
            try self.focusPane(target);
            try self.history.add(path);
            return;
        }
    }
    try self.focusPane(target);
    self.requestOpenPath(path);
}

fn quickConfigureBinding(context: *anyopaque, id: []const u8) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try commandOpenKeybindingsJson(context);
    const tab = self.activeTab() orelse return;
    try tab.ensureControllers();
    const find = tab.controllers.?.find;
    try find.startFind();
    try find.widget().find_input.setValue(id);
}

fn quickLookupKeycaps(context: *anyopaque, arena: Allocator, id: []const u8) anyerror![]const []const u8 {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const global = try self.ensureGlobalService();
    const binding = try global.service.lookupKeybinding(arena, id, false) orelse try (try self.ensureTabService()).service.lookupKeybinding(arena, id, false) orelse blk: {
        const tab = self.activeTab() orelse return &.{};
        if (tab.isDiff()) return &.{};
        break :blk try tab.editor.lookupShortcut(id) orelse return &.{};
    };
    return @import("./quickaccess.zig").keycaps(arena, binding);
}

fn quickGetExcludes(context: *anyopaque, allocator: Allocator) anyerror![]glob.ExcludeEntry {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.ensureConfiguration() catch {};
    const configuration = self.configuration orelse return allocator.alloc(glob.ExcludeEntry, 0);
    return search_types.getExcludes(
        allocator,
        configuration.getValue("files.exclude", .{}),
        configuration.getValue("search.exclude", .{}),
    );
}

fn quickGetFileSearchSettings(context: *anyopaque) search_types.FileSearchSettings {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.ensureConfiguration() catch {};
    const configuration = self.configuration orelse return .{};
    return .{
        .use_ignore_files = configuration.getBool("search.useIgnoreFiles", true),
        .use_parent_ignore_files = configuration.getBool("search.useParentIgnoreFiles", true),
        .use_global_ignore_files = configuration.getBool("search.useGlobalIgnoreFiles", true),
        .follow_symlinks = configuration.getBool("search.followSymlinks", true),
    };
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

fn problemsWorkspaceRoot(context: *anyopaque) ?[]const u8 {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.workspaceFolderPath();
}

fn problemsOpenEditor(context: *anyopaque, marker: *const markers_mod.Marker, preserve_focus: bool, pinned: bool) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.openPathWithOptions(marker.resource.path, .{ .pinned = pinned, .preserve_focus = preserve_focus });
    const tab = self.activeTab() orelse return;
    try tab.editor.setSelection(tab.editor.model.validateRange(MarkersView.markerRange(marker)));
    if (preserve_focus) {
        self.updateProblemsHighlight();
    } else {
        self.focusEditor();
        tab.focusEditor();
    }
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

fn commandViewScm(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (!try self.showActivityById("scm")) return;
    self.focusSidebar();
    if (self.scm.changes) |view| view.refresh();
}

fn commandShowProblems(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.showProblems();
}

fn commandToggleProblems(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.toggleProblems();
}

fn commandTogglePanel(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.geometry().panelShown()) {
        self.hidePanel();
        return;
    }
    const id = self.defaultPanelContainerId() orelse return;
    _ = try self.openPanelContainer(id);
}

fn zenTabsHideAvailable(context: *anyopaque) bool {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.layout.isZenModeActive() and self.zenModeConfiguration().show_tabs != .none;
}

fn zenTabsMultipleAvailable(context: *anyopaque) bool {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.layout.isZenModeActive() and self.zenModeConfiguration().show_tabs != .multiple;
}

fn zenTabsSingleAvailable(context: *anyopaque) bool {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return self.layout.isZenModeActive() and self.zenModeConfiguration().show_tabs != .single;
}

fn commandZenSetEditorTabs(context: *anyopaque, mode: layout_service_mod.EditorTabsMode) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.setUserConfigurationValue(
        layout_service_mod.ZenModeSettings.show_tabs,
        .{ .string = zen_mode_contribution.showTabsValue(mode) },
    );
}

fn commandZenHideEditorTabs(context: *anyopaque) anyerror!void {
    try commandZenSetEditorTabs(context, .none);
}

fn commandZenShowMultipleEditorTabs(context: *anyopaque) anyerror!void {
    try commandZenSetEditorTabs(context, .multiple);
}

fn commandZenShowSingleEditorTab(context: *anyopaque) anyerror!void {
    try commandZenSetEditorTabs(context, .single);
}

fn commandFocusPanel(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (!self.geometry().panelShown()) {
        const id = self.defaultPanelContainerId() orelse return;
        _ = try self.openPanelContainer(id);
        return;
    }
    if (std.mem.eql(u8, self.geometry().activePanelId(), PROBLEMS_CONTAINER_ID)) {
        self.setFocus(.problems);
    } else if (std.mem.eql(u8, self.geometry().activePanelId(), TERMINAL_CONTAINER_ID)) {
        self.setFocus(.terminal);
    }
    self.updateProblemsHighlight();
}

fn commandPreviousPanelView(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = try self.cyclePanelView(-1);
}

fn commandNextPanelView(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = try self.cyclePanelView(1);
}

fn commandGitRefresh(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.refreshGitStatus();
    if (self.scm.history) |view| {
        view.outdated = false;
        view.refresh(.reload) catch {};
    }
}

fn commandGitCommit(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const view = self.scm.changes orelse return;
    _ = view.commitInput();
}

fn commandScmMenu(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const container = self.scm_container orelse return;
    try self.showSidebarViewMenu(container, .overflow, null, self.sidebarMenuAnchor("workbench.scm.action.showMenu"));
}

fn commandScmChangesMenu(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const view = self.scm.changes orelse return;
    const menu = try self.newContextMenu(runTitleMenuAction);
    errdefer menu.deinit();
    try scm_view_mod.appendSecondary(menu, &self.menu_service, (try self.ensureContextKeys()).interface().getContext(), view);
    try self.showContextMenu(menu, self.sidebarMenuAnchor(scm_view_mod.CHANGES_MENU_ACTION_ID));
}

fn commandScmGraphMenu(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const view = self.scm.history orelse return;
    const menu = try self.newContextMenu(runTitleMenuAction);
    errdefer menu.deinit();
    try scm_history_view_mod.appendSecondary(menu, &self.menu_service, (try self.ensureContextKeys()).interface().getContext(), view);
    try self.showContextMenu(menu, self.sidebarMenuAnchor(scm_history_view_mod.GRAPH_MENU_ACTION_ID));
}

fn runTitleMenuAction(self: *Workbench, _: *MenuActionContext, id: []const u8) anyerror!void {
    try self.commands.execute(id);
}

fn commandGitFetch(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.runScmRemoteAction(.fetch, null) catch |err| self.setStatusHint("Fetch failed: {s}", .{@errorName(err)});
}

fn commandGitPull(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.runScmRemoteAction(.pull, null) catch |err| self.setStatusHint("Pull failed: {s}", .{@errorName(err)});
}

fn commandGitPush(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.runScmRemoteAction(.push, null) catch |err| self.setStatusHint("Push failed: {s}", .{@errorName(err)});
}

fn commandGitPublish(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const provider = self.git_model.repository orelse return;
    const remotes = provider.repository.stateRef().remotes;
    var items: std.ArrayList(QuickPickItem) = .empty;
    defer items.deinit(self.allocator);
    for (remotes) |remote| {
        if (!remote.is_read_only) try items.append(self.allocator, .{ .item = .{ .id = remote.name, .label = remote.name } });
    }
    if (items.items.len == 0) {
        self.setStatusHint("No remote to publish to", .{});
        return;
    }
    try self.quick_access.inputService().showPick(items.items, .{ .placeholder = "Select a Remote to Publish the Branch" }, onGitPublishPick, self);
}

fn onGitPublishPick(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const item = picker.selectedItem() orelse picker.activeItem() orelse return;
    self.runScmRemoteAction(.publish, item.id) catch |err| self.setStatusHint("Publish failed: {s}", .{@errorName(err)});
}

fn commandGitOpenChange(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const view = self.scm.changes orelse return;
    const resource = view.selectedResource() orelse return;
    const provider = self.git_model.repository orelse return;
    const git_resource: *repository_mod.GitScmResource = @ptrCast(@alignCast(resource.context));
    try self.openScmChange(provider, git_resource);
}

fn commandGitOpenFile(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return;
    const diff = tab.diff orelse return;
    try self.openPath(diff.model.modified_path);
}

/// The hover insets its content two cells on every side. Glyph borders use
/// one of those cells, while native borders are painted on the overlay edges.
/// The DOM root uses content-box sizing, so each dimension is four cells
/// smaller than the surface.
fn commandDiffNext(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.activeTab()) |tab| _ = tab.nextDiffChange();
}

fn commandDiffPrevious(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.activeTab()) |tab| _ = tab.previousDiffChange();
}

fn commandDiffSwap(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.activeTab()) |tab| tab.swapDiffSides();
}

fn commandDiffRefresh(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return;
    const diff = tab.diff orelse return;
    if (!isDiffRefLabel(diff.model.original_label) or !isDiffRefLabel(diff.model.modified_label)) {
        // Commit-to-commit diffs keep display ids as labels; there is no ref to
        // re-resolve from the workbench state, so leave them unchanged.
        return;
    }
    const left = diffRefFromLabel(diff.model.original_label);
    const right = diffRefFromLabel(diff.model.modified_label);
    try self.openDiff(diff.model.modified_path, left, right);
}

fn isDiffRefLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "HEAD") or
        std.mem.eql(u8, label, "Index") or
        std.mem.eql(u8, label, "Working Tree") or
        std.mem.eql(u8, label, "Empty");
}

fn diffRefFromLabel(label: []const u8) DiffRef {
    if (std.mem.eql(u8, label, "HEAD")) return .head;
    if (std.mem.eql(u8, label, "Index")) return .index;
    if (std.mem.eql(u8, label, "Working Tree")) return .working;
    return .empty;
}

fn commandSave(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    if (tab.isDiff() or tab.isImage()) return;
    try tab.editor.save();
}

fn commandRevert(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    if (tab.isDiff() or tab.isImage()) return;
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

fn commandFocusOutline(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const location = if (self.scm_view_model) |model| if (model.contains("outline")) "scm" else "explorer" else "explorer";
    _ = try self.showActivityById(location);
    if (self.activeSidebarViewContainer()) |container| {
        container.model.setVisible("outline", true);
        container.model.setCollapsed("outline", false);
        container.setActive("outline");
    }
    self.focusSidebar();
    self.syncOutlineView() catch {};
    if (self.outline_view) |view| view.setFocused(true);
    self.updateSidebarTitleActions();
}

fn commandOutlineMoreActions(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const view = self.outline_view orelse return;
    const menu = try self.newContextMenu(runTitleMenuAction);
    errdefer menu.deinit();
    try @import("../contrib/outline/browser/outlineActions.zig").appendSecondary(menu, &self.menu_service, (try self.ensureContextKeys()).interface().getContext(), &view.view_state);
    try self.showContextMenu(menu, self.sidebarMenuAnchor(OutlinePane.more_actions_id));
}

fn commandOutlineCollapse(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.outline_view) |view| {
        view.collapseAll();
        self.updateSidebarTitleActions();
    }
}

fn commandOutlineExpand(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.outline_view) |view| {
        view.expandAll();
        self.updateSidebarTitleActions();
    }
}

fn commandOutlineFollowCursor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.outline_view) |view| {
        try view.setFollowCursor(!view.view_state.follow_cursor);
        self.updateSidebarTitleActions();
    }
}

fn commandOutlineFilterOnType(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.outline_view) |view| {
        try view.setFilterOnType(!view.view_state.filter_on_type);
        self.updateSidebarTitleActions();
    }
}

fn commandOutlineSortByPosition(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.outline_view) |view| {
        try view.setSortBy(.ByPosition);
        self.updateSidebarTitleActions();
    }
}

fn commandOutlineSortByName(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.outline_view) |view| {
        try view.setSortBy(.ByName);
        self.updateSidebarTitleActions();
    }
}

fn commandOutlineSortByKind(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.outline_view) |view| {
        try view.setSortBy(.ByKind);
        self.updateSidebarTitleActions();
    }
}

fn commandCloseEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = try self.closeActive();
}

fn commandReopenClosedEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = self.reopenLastClosedEditor();
}

fn commandShowMarkdownSource(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.showMarkdownSource();
}

fn commandOpenMarkdownPreview(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.openMarkdownPanel(false);
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

fn commandImageOpenInTextEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.openActiveImageAsText();
}

fn commandRefreshMarkdownPreview(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.refreshMarkdownPreview();
}

fn runSplitCommand(self: *Workbench, direction: editor_groups.GroupDirection) anyerror!void {
    self.splitActiveInDirection(direction) catch |err| switch (err) {
        // The terminal diff/snapshot pane owns its models and cannot be
        // duplicated yet; report the terminal limitation instead of failing
        // the command handler with no visible feedback.
        error.SplitUnsupported => self.setStatusHint("Split Editor is unavailable for this editor type", .{}),
        else => return err,
    };
}

fn commandSplitEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try runSplitCommand(self, self.preferredSideBySideDirection());
}

fn commandSplitEditorOrthogonal(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    // Upstream `SplitEditorOrthogonalAction.getDirection`: the opposite axis
    // of `workbench.editor.openSideBySideDirection`.
    try runSplitCommand(self, if (self.preferredSideBySideDirection() == .RIGHT) .DOWN else .RIGHT);
}

fn commandSplitEditorLeft(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try runSplitCommand(self, .LEFT);
}

fn commandSplitEditorRight(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try runSplitCommand(self, .RIGHT);
}

fn commandSplitEditorUp(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try runSplitCommand(self, .UP);
}

fn commandSplitEditorDown(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try runSplitCommand(self, .DOWN);
}

fn commandCloseGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.closeActiveGroup();
}

fn commandJoinTwoGroups(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.joinTwoGroups();
}

fn commandDuplicateGroupLeft(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.duplicateActiveGroup(.LEFT) catch |err| return splitCommandError(self, err);
}

fn commandDuplicateGroupRight(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.duplicateActiveGroup(.RIGHT) catch |err| return splitCommandError(self, err);
}

fn commandDuplicateGroupUp(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.duplicateActiveGroup(.UP) catch |err| return splitCommandError(self, err);
}

fn commandDuplicateGroupDown(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.duplicateActiveGroup(.DOWN) catch |err| return splitCommandError(self, err);
}

fn commandMoveEditorToPreviousGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.moveOrSplitActiveEditor(.previous, false);
}

fn commandMoveEditorToNextGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.moveOrSplitActiveEditor(.next, false);
}

fn commandMoveEditorToAboveGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.moveOrSplitActiveEditor(.up, false);
}

fn commandMoveEditorToBelowGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.moveOrSplitActiveEditor(.down, false);
}

fn commandMoveEditorToLeftGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.moveOrSplitActiveEditor(.left, false);
}

fn commandMoveEditorToRightGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.moveOrSplitActiveEditor(.right, false);
}

fn commandMoveEditorToFirstGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.moveOrSplitActiveEditor(.first, false);
}

fn commandMoveEditorToLastGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.moveOrSplitActiveEditor(.last, false);
}

fn commandSplitEditorToPreviousGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.moveOrSplitActiveEditor(.previous, true) catch |err| return splitCommandError(self, err);
}

fn commandSplitEditorToNextGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.moveOrSplitActiveEditor(.next, true) catch |err| return splitCommandError(self, err);
}

fn commandSplitEditorToAboveGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.moveOrSplitActiveEditor(.up, true) catch |err| return splitCommandError(self, err);
}

fn commandSplitEditorToBelowGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.moveOrSplitActiveEditor(.down, true) catch |err| return splitCommandError(self, err);
}

fn commandSplitEditorToLeftGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.moveOrSplitActiveEditor(.left, true) catch |err| return splitCommandError(self, err);
}

fn commandSplitEditorToRightGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.moveOrSplitActiveEditor(.right, true) catch |err| return splitCommandError(self, err);
}

fn commandSplitEditorToFirstGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.moveOrSplitActiveEditor(.first, true) catch |err| return splitCommandError(self, err);
}

fn commandSplitEditorToLastGroup(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.moveOrSplitActiveEditor(.last, true) catch |err| return splitCommandError(self, err);
}

fn splitCommandError(self: *Workbench, err: anyerror) anyerror!void {
    switch (err) {
        error.SplitUnsupported => self.setStatusHint("Split Editor is unavailable for this editor type", .{}),
        else => return err,
    }
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

fn commandGithubPublish(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const folder = if (self.git_model.repository) |provider| provider.root else self.workspaceFolderPath() orelse {
        self.setStatusHint("Open a folder to publish to GitHub", .{});
        return;
    };
    const executable = try terminal_profiles.findTerminalExecutable(self.allocator, self.io, "gh") orelse {
        self.setStatusHint("Install GitHub CLI and add gh to PATH to publish a repository", .{});
        return;
    };
    defer self.allocator.free(executable);
    _ = try self.launchTerminalProcess("Publish to GitHub", executable, &.{ "repo", "create" }, folder);
}

fn reportEditorMessage(context: *anyopaque, message: []const u8) bool {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return false;
    tab.editor.setMessage("{s}", .{message});
    return true;
}

fn commandViewExplorer(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.showExplorer();
}

fn commandCloseSidebar(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (!self.sidebar_part.isVisible()) return;
    try self.setSidebarVisible(false);
    self.setFocus(.editor);
    self.layoutAll();
}

fn commandFocusSidebar(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.sidebar == null) return;
    try self.setSidebarVisible(true);
    self.focusSidebar();
    self.layoutAll();
}

fn commandPreviousSidebarView(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try switchSidebarView(self, -1);
}

fn commandNextSidebarView(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try switchSidebarView(self, 1);
}

/// Port of `SwitchCompositeViewAction`: cycles through the visible side bar
/// view containers in composite-bar order.
fn switchSidebarView(self: *Workbench, offset: isize) !void {
    const target = try self.sidebar_part.switchViewTarget(offset, self.allocator) orelse return;
    _ = try self.showActivityById(target);
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
        if (self.scm_container) |container| {
            _ = try container.handleKey(&event);
            return;
        }
        if (self.scm.changes) |view| {
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
    try openConfigJson(self, self.user_keybindings.paths, "[\n]\n");
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

fn onTerminalMenu(self: *Workbench, _: *MenuActionContext, id: []const u8) anyerror!void {
    try runTerminalAction(self, id);
}

fn runTerminalAction(self: *Workbench, action_id: []const u8) !void {
    const service = self.terminal_service orelse return;
    try terminal_actions.runMenuAction(service, .{
        .context = self,
        .part = self.part,
        .view_factory = self.view_factory,
        .quick_input = self.quick_access.inputService(),
        .set_user_configuration = struct {
            fn run(context: *anyopaque, key: []const u8, value: std.json.Value) !void {
                const host: *Workbench = @ptrCast(@alignCast(context));
                try host.setUserConfigurationValue(key, value);
                host.layoutAll();
            }
        }.run,
        .reveal_panel = struct {
            fn run(context: *anyopaque) !void {
                const host: *Workbench = @ptrCast(@alignCast(context));
                try host.showTerminal();
            }
        }.run,
        .reveal_editor = struct {
            fn run(context: *anyopaque, moved: bool) !void {
                const host: *Workbench = @ptrCast(@alignCast(context));
                try host.revealTerminalEditorMoved(moved);
            }
        }.run,
        .panel_instances_removed = struct {
            fn run(context: *anyopaque) !void {
                const host: *Workbench = @ptrCast(@alignCast(context));
                try host.onPanelTerminalsRemoved(host.terminal_service.?);
            }
        }.run,
    }, action_id);
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

fn commandToggleStickyScroll(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.ensureControllers();
    if (tab.controllers) |controllers| controllers.sticky.toggle();
}

fn commandFocusStickyScroll(context: *anyopaque) anyerror!void {
    const tab = try commandTab(context);
    try tab.ensureControllers();
    if (tab.controllers) |controllers| controllers.sticky.focus();
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

fn startSearchEditorJob(context: *anyopaque, query: *const search_types.TextQuery) !search_types.ISearchJob {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.search_service == null) try self.initSearchFromWorkspace();
    return self.search_service.?.startTextSearch(query);
}

fn searchEditorEnvironment(context: *anyopaque) ?search_editor_input_mod.Environment {
    const self: *Workbench = @ptrCast(@alignCast(context));
    return .{ .workspace = self.workspace, .configuration = self.configuration orelse return null };
}

fn searchOpenResults(context: *anyopaque, config: search_editor.Config, snapshot: search_editor_serialization.Snapshot) !void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const pane = self.activePane() orelse return error.GroupPaneMissing;
    try self.ensureConfiguration();
    const configuration = self.configuration.?;
    const dims = pane.contentDimensions();
    const query = try search_editor.SearchEditor.init(self.allocator, .{ .context = self, .start_text_search = startSearchEditorJob }, config, configuration);
    _ = query.on_did_change_query_focus.listenSignal(self, Workbench.updatePartFocus) catch |err| {
        query.deinit();
        return err;
    };
    const input = SearchEditorInput.init(self.allocator, self.io, config.query, query, snapshot.text, dims.width, dims.height) catch |err| {
        query.deinit();
        return err;
    };
    const tab = Tab.initSearchEditor(self.view_factory, self.allocator, input) catch |err| {
        input.deinit();
        return err;
    };
    errdefer tab.deinit();
    try tab.view.setStatusBarVisible(false);
    try input.setMatchRanges(snapshot.match_ranges);
    try query.setLocations(snapshot.files);
    input.attach(&self.window_events, .{ .context = self, .environment = searchEditorEnvironment, .extra_files = searchExtraFiles, .free_paths = searchFreePaths });
    try pane.tabs.ensureUnusedCapacity(1);
    _ = try pane.group.model.openEditor(tab.input, .{ .pinned = true, .active = true });
    try pane.addTab(tab);
    self.applyEditorSettingsToTab(tab);
    self.layoutAll();
    self.focusEditor();
    if (config.query.len > 0 and query.form.contextLines() > 0) query.triggerSearch(0, true);
}

pub fn searchEditorOpenTarget(self: *Workbench, tab: *Tab) bool {
    const query = tab.search_editor_input.?.search_editor;
    const target = (query.targetAtCursor(tab.editor) catch null) orelse return false;
    searchOpenMatch(self, target.path, target.range) catch |err| {
        tab.editor.setMessage("Open failed: {s}", .{@errorName(err)});
    };
    return true;
}

fn searchOpenMatch(context: *anyopaque, path: []const u8, range: ?Range) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.openPath(path);
    self.setFocus(.editor);
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

fn searchOpenFiles(context: *anyopaque, allocator: Allocator) anyerror![][]u8 {
    const self: *Workbench = @ptrCast(@alignCast(context));
    var paths = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }
    for (self.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| {
            if (tab.search_editor_input != null) continue;
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

fn searchExtraFiles(context: *anyopaque, allocator: Allocator) anyerror![][]u8 {
    const self: *Workbench = @ptrCast(@alignCast(context));
    var paths = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }
    for (self.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| {
            if (tab.search_editor_input != null) continue;
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

fn searchConfirmReplaceAll(context: *anyopaque, message: []const u8) !void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.isDialogOpen()) return error.DialogAlreadyOpen;
    _ = try self.dialog_service.confirm(.{ .message = message, .primary_button = "Replace" }, .{ .context = self, .complete = onSearchReplaceAllConfirmed });
}

fn onSearchReplaceAllConfirmed(context: *anyopaque, result: dialogs.IConfirmationResult) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.search_view) |view| {
        if (result.confirmed) view.confirmReplaceAll() else view.clearReplaceConfirmation();
    }
}

fn searchTextModel(context: *anyopaque, path: []const u8) ?*@import("../../editor/common/model/textModel.zig").TextModel {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const input = self.findOpenInput(path) orelse return null;
    return input.editor.model;
}

fn commandOpenNewSearchEditor(context: *anyopaque) anyerror!void {
    try searchOpenResults(context, .{}, .{ .text = "", .match_ranges = &.{} });
}

fn commandRerunSearchEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return;
    if (tab.search_editor_input) |input| input.search_editor.triggerSearch(0, true);
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

const terminal_focus_when = context_key_mod.Expr{ .Defined = "terminalFocus" };
const Expr = context_key_mod.Expr;
const markdown_language_when = Expr{ .Regex = .{ .key = "editorLangId", .source = "^(markdown|prompt|instructions|chatagent|skill)$", .flags = "" } };
const markdown_source_when = Expr{ .And = @constCast(&[_]*const Expr{ &.{ .Defined = "editorFocus" }, &markdown_language_when }) };
const markdown_toggle_when = Expr{ .Or = @constCast(&[_]*const Expr{ &markdown_source_when, &.{ .Equals = .{ .key = "activeCustomEditorId", .value = .{ .string = "vscode.markdown.preview.editor" } } } }) };

const global_keybinding_rules = [_]keybinding_registry.IKeybindingRule{
    .{ .id = "workbench.action.splitEditor", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.Backslash) } },
    .{ .id = terminal_common.TerminalCommandId.split, .weight = 201, .when = &terminal_focus_when, .bindings = .{
        .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.Backslash),
        .secondary = &.{key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.Digit5)},
    } },
    .{ .id = "workbench.action.splitEditorOrthogonal", .weight = 200, .bindings = .{ .primary = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.Backslash)) } },
    .{ .id = "workbench.action.quickOpen", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyP) } },
    .{ .id = "workbench.action.findInFiles", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyF), .secondary = &.{key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyF)} } },
    .{ .id = "workbench.action.replaceInFiles", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyH) } },
    .{ .id = "workbench.action.toggleSidebarVisibility", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyB) } },
    .{ .id = "workbench.action.focusSideBar", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.Digit0) } },
    .{ .id = "workbench.action.focusStatusBar", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyS) } },
    .{ .id = markers_common.Markers.TOGGLE_MARKERS_VIEW_ACTION_ID, .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyM) } },
    .{ .id = "workbench.action.togglePanel", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyJ) } },
    .{ .id = "breadcrumbs.focusAndSelect", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.Period) } },
    .{ .id = "breadcrumbs.focus", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.Semicolon) } },
    .{ .id = "workbench.action.terminal.toggleTerminal", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyT) } },
    .{ .id = "markdown.showPreviewToSide", .weight = 200, .when = &markdown_source_when, .bindings = .{ .primary = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), @backingInt(key_codes.KeyCode.KeyV)) } },
    .{ .id = "markdown.togglePreview", .weight = 200, .when = &markdown_toggle_when, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyV) } },
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
    if (self.terminalFocused() and !terminalCommandSkipsShell(command_id)) {
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

/// Process environment for the async Io instance. Mirrors the worker helpers
/// in `search/node/*Worker.zig` and `extensionHostManager.zig`: the terminal's
/// Io needs the environment for executable resolution/spawn and for HTTP proxy
/// discovery, but the library must not assume libc is linked.
fn readHomePath(allocator: Allocator) ?[]u8 {
    if (builtin.os.tag == .windows) return null;
    var map = std.process.Environ.Map.init(allocator);
    defer map.deinit();
    const environ = asyncEnviron();
    map.putPosixBlock(.{ .slice = @ptrCast(environ.block.slice) }) catch return null;
    const value = map.get("HOME") orelse return null;
    return allocator.dupe(u8, value) catch null;
}

fn asyncEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => if (builtin.link_libc)
            .{ .block = .{ .slice = @ptrCast(@as([:null]?[*:0]u8, std.mem.span(std.c.environ))) } }
        else
            .empty,
    };
}
