//! Native terminal workbench window and composition adapter. The portable
//! Workbench in src/vs/workbench/browser/workbench.zig owns layout, startup,
//! notifications and lifecycle. This window owns native service instances
//! and host wiring; remaining feature commands are audited in
//! docs/workbench-audit.md. Terminal input/rendering live in workbench.zig.
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
//! The sidebar and panel use the same rounded frame treatment, adapting
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
const editor_css = @import("../vs/editor/browser/editorCss.zig");
const grid_mod = @import("../vs/base/browser/ui/grid/grid.zig");
const sash_css = @import("../vs/base/browser/ui/sash/sash_css.zig");
const editor_drop_target = @import("../vs/workbench/browser/parts/editor/editorDropTarget.zig");
const editor_tabs_control = @import("../vs/workbench/browser/parts/editor/editorTabsControl.zig");
const editor_group_view = @import("../vs/workbench/browser/parts/editor/editorGroupView.zig");
const editor_group_watermark = @import("../vs/workbench/browser/parts/editor/editorGroupWatermark.zig");
const editor_part = @import("../vs/workbench/browser/parts/editor/editorPart.zig");
const Tab = @import("../vs/workbench/browser/parts/editor/editorPane.zig").Tab;
const FileEditorInput = @import("../vs/workbench/contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const FileEditorSerializer = @import("../vs/workbench/contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorSerializer;
const editor_factory = @import("../vs/workbench/common/editor/editorFactory.zig");
const tui_editor_mod = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
const Editor = tui_editor_mod.Editor;
const tab_bar = @import("../vs/workbench/browser/parts/editor/multiEditorTabsControl.zig");
const file_icon = @import("../vs/workbench/services/themes/browser/fileIconThemeData.zig");
const Sidebar = @import("../vs/workbench/contrib/files/browser/views/explorerView.zig").Sidebar;
const activity_bar_mod = @import("../vs/workbench/browser/parts/activitybar/activitybarPart.zig");
const ActivityBarPart = @import("../vs/workbench/browser/parts/activitybar/activitybarPart.zig").ActivityBarPart;
const sidebar_part_mod = @import("../vs/workbench/browser/parts/sidebar/sidebarPart.zig");
const SidebarPart = sidebar_part_mod.SidebarPart;
const layout_service_mod = @import("../vs/workbench/services/layout/browser/layoutService.zig");
const workbench_layout = @import("../vs/workbench/browser/layout.zig");
const Layout = workbench_layout.Layout;
const workbench_core = @import("../vs/workbench/browser/workbench.zig");
const code_editor_service = @import("../vs/editor/browser/services/codeEditorService.zig");
const CodeEditorService = @import("../vs/workbench/services/editor/browser/codeEditorService.zig").CodeEditorService;
const WorkbenchGrid = workbench_layout.WorkbenchGrid;
const statusbar_mod = @import("../vs/workbench/browser/parts/statusbar/statusbarPart.zig");
const StatusbarService = statusbar_mod.StatusbarService;
const EntryAccessor = statusbar_mod.EntryAccessor;
const statusbar_types = @import("../vs/workbench/services/statusbar/browser/statusbar.zig");
const ActivityService = @import("../vs/workbench/services/activity/browser/activityService.zig").ActivityService;
const history_mod = @import("../vs/workbench/services/history/browser/historyService.zig");
const HistoryService = history_mod.HistoryService;
const commands_mod = @import("../vs/workbench/browser/commands.zig");
const CommandRegistry = commands_mod.CommandRegistry;
const SimpleBrowserManager = @import("../extensions/simple-browser/src/simpleBrowserManager.zig").SimpleBrowserManager;
const terminal_platform = @import("../vs/platform/terminal/common/terminal.zig");
const quick_access_mod = @import("../vs/workbench/browser/quickaccess.zig");
const QuickAccessService = quick_access_mod.QuickAccessService;
const editor_status_mod = @import("../vs/workbench/browser/parts/editor/editorStatus.zig");
const EditorStatus = editor_status_mod.EditorStatus;
const workspace_context = @import("../vs/workbench/services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const configuration_mod = @import("../vs/workbench/services/configuration/browser/configurationService.zig");
const workbench_configuration = @import("../vs/workbench/browser/workbenchConfiguration.zig");
const zen_mode_contribution = @import("../vs/workbench/browser/workbench.zenMode.contribution.zig");

const ConfigurationService = configuration_mod.ConfigurationService;
const file_watcher_service_mod = @import("../vs/platform/files/node/watcher/fileWatcherService.zig");
const FileWatcherService = file_watcher_service_mod.FileWatcherService;
const contributions_mod = @import("../vs/workbench/common/contributions.zig");
const workspace_watcher_mod = @import("../vs/workbench/contrib/files/browser/workspaceWatcher.zig");
const WorkspaceWatcher = workspace_watcher_mod.WorkspaceWatcher;
const working_copy_service_mod = @import("../vs/workbench/services/workingCopy/common/workingCopyService.zig");
const WorkingCopyService = working_copy_service_mod.WorkingCopyService;
const keybinding_service = @import("../vs/workbench/services/keybinding/browser/keybindingService.zig");
const key_codes = @import("../vs/base/common/keyCodes.zig");
const keybinding_registry = @import("../vs/platform/keybinding/common/keybindingsRegistry.zig");
const resolved_keybinding_item = @import("../vs/platform/keybinding/common/resolvedKeybindingItem.zig");
const context_key_mod = @import("../vs/platform/contextkey/common/contextkey.zig");
const user_keybindings_mod = @import("../vs/workbench/services/keybinding/browser/userKeybindings.zig");
const theme_service_mod = @import("../vs/workbench/services/themes/browser/workbenchThemeService.zig");
const theme_configuration_mod = @import("../vs/workbench/services/themes/common/themeConfiguration.zig");
const host_color_scheme_mod = @import("../vs/workbench/services/themes/common/hostColorSchemeService.zig");
const syntax_theme_mod = @import("../vs/editor/standalone/browser/standaloneThemeService.zig");
const textmate_background_mod = @import("../vs/workbench/services/textMate/browser/backgroundTokenization/threadedBackgroundTokenizerFactory.zig");
const TokenizationRegistry = @import("../vs/editor/common/tokenizationRegistry.zig").TokenizationRegistry;
const theme_colors_mod = @import("../vs/workbench/browser/themeColors.zig");
const SettingsWatcher = configuration_mod.SettingsWatcher;
const IDisposable = @import("../vs/base/common/lifecycle.zig").IDisposable;
const breadcrumbs_control_mod = @import("../vs/workbench/browser/parts/editor/breadcrumbsControl.zig");
const BreadcrumbsControl = breadcrumbs_control_mod.BreadcrumbsControl;
const outline_service_mod = @import("../vs/workbench/services/outline/browser/outlineService.zig");
const OutlineService = outline_service_mod.OutlineService;
const outline_mod = @import("../vs/workbench/services/outline/browser/outline.zig");
const OutlineEditor = outline_mod.OutlineEditor;
const IOutlineCreator = outline_mod.IOutlineCreator;
const DocumentSymbolsOutlineCreator = @import("../vs/workbench/contrib/codeEditor/browser/outline/documentSymbolsOutline.zig").DocumentSymbolsOutlineCreator;
const outline_model = @import("../vs/editor/contrib/documentSymbols/browser/outlineModel.zig");
const Emitter = @import("../vs/base/common/event.zig").Emitter;
const lifecycle_mod = @import("../vs/workbench/services/lifecycle/common/lifecycle.zig");
const ServiceCollection = @import("../vs/platform/instantiation/common/serviceCollection.zig").ServiceCollection;
const InstantiationService = @import("../vs/platform/instantiation/common/instantiationService.zig").InstantiationService;
const outline_pane_mod = @import("../vs/workbench/contrib/outline/browser/outlinePane.zig");
const OutlinePane = outline_pane_mod.OutlinePane;
const outline_contrib = @import("../vs/workbench/contrib/outline/browser/outline.zig");
const OutlineSortOrder = outline_contrib.OutlineSortOrder;
const quick_input_common = @import("../vs/platform/quickinput/common/quickInput.zig");
const QuickPickItem = quick_input_common.QuickPickItem;
const QuickPick = @import("../vs/platform/quickinput/browser/quickInput.zig").QuickPick;
const dialogs = @import("../vs/platform/dialogs/common/dialogs.zig");
const markers_common = @import("../vs/workbench/contrib/markers/common/markers.zig");
const markers_contribution = @import("../vs/workbench/contrib/markers/browser/markers.contribution.zig");
const MarkersStatusBar = @import("../vs/workbench/contrib/markers/browser/markersStatusBar.zig").MarkersStatusBar;
const pane_composite_mod = @import("../vs/workbench/browser/parts/paneCompositePart.zig");

/// Upstream `Markers.MARKERS_CONTAINER_ID` and `TERMINAL_VIEW_ID`.
const PROBLEMS_CONTAINER_ID = markers_common.Markers.MARKERS_CONTAINER_ID;
const BulkEditPane = @import("../vs/workbench/contrib/bulkEdit/browser/preview/bulkEditPane.zig").BulkEditPane;
const BulkEditPreviewContribution = @import("../vs/workbench/contrib/bulkEdit/browser/preview/bulkEdit.contribution.zig").BulkEditPreviewContribution;
const TERMINAL_CONTAINER_ID = "terminal";
const MarkersView = @import("../vs/workbench/contrib/markers/browser/markersView.zig").MarkersView;
const panel_part_mod = @import("../vs/workbench/browser/parts/panel/panelPart.zig");
const PanelPart = panel_part_mod.PanelPart;
const views_mod = @import("../vs/workbench/common/views.zig");
const view_descriptor_service_mod = @import("../vs/workbench/services/views/browser/viewDescriptorService.zig");
const ViewDescriptorService = view_descriptor_service_mod.ViewDescriptorService;
const range_highlight_mod = @import("../vs/workbench/browser/codeeditor.zig");
const RangeHighlightDecorations = range_highlight_mod.RangeHighlightDecorations;

const search_view_mod = @import("../vs/workbench/contrib/search/browser/searchViewTerminal.zig");
const SearchView = search_view_mod.SearchView;
const search_widget_mod = @import("../vs/workbench/contrib/search/browser/searchWidget.zig");
const glob = @import("../vs/base/common/glob.zig");
const search_types = @import("../vs/workbench/services/search/common/search.zig");
const FileContentProvider = search_types.FileContentProvider;
const search_configuration = @import("../vs/workbench/contrib/search/common/searchConfiguration.zig");
const tree = @import("../vs/workbench/contrib/search/browser/searchTreeModel/searchTreeCommon.zig");
const group_mod = @import("../vs/workbench/common/editor/editorGroupModel.zig");
const editor_service_mod = @import("../vs/workbench/services/editor/browser/editorService.zig");
const editor_groups = @import("../vs/workbench/services/editor/common/editorGroupsService.zig");
const extensions_registry = @import("../vs/workbench/services/extensions/common/extensionsRegistry.zig");
const time_compat = @import("../vs/base/common/timeCompat.zig");
const json_language = @import("../vs/workbench/services/language/common/jsonLanguageClient.zig");
const configuration_extension_point = @import("../vs/workbench/api/common/configurationExtensionPoint.zig");
const editor_input = @import("../vs/workbench/common/editor/editorInput.zig");
const EditorInput = editor_input.EditorInput;
const Range = @import("../vs/editor/common/core/range.zig").Range;
const LanguageFeaturesService = @import("../vs/editor/common/services/languageFeaturesService.zig").LanguageFeaturesService;
const languages = @import("../vs/editor/common/languages.zig");
const go_to_commands = @import("../vs/editor/contrib/gotoSymbol/browser/goToCommands.zig");
const goto_symbol_quick_access = @import("../vs/workbench/contrib/codeEditor/browser/quickaccess/gotoSymbolQuickAccess.zig");
const hover_actions = @import("../vs/editor/contrib/hover/browser/hoverActions.zig");
const MarkdownPreviewManager = @import("../extensions/markdown-language-features/src/preview/previewManager.zig").MarkdownPreviewManager;
const ImagePreviewEditorInput = @import("../vs/workbench/contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInput;
const ImagePreviewEditorInputSerializer = @import("../vs/workbench/contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInputSerializer;
const MediaPreviewStatus = @import("../vs/workbench/contrib/mediaPreview/browser/mediaPreviewStatusBar.zig").MediaPreviewStatus;
const media_actions = @import("../vs/workbench/contrib/mediaPreview/browser/mediaPreviewActions.zig");
const std_uri = @import("../vs/base/common/stdUri.zig");
const MarkerService = @import("../vs/platform/markers/common/markerService.zig").MarkerService;
const MarkerChangeEvent = @import("../vs/platform/markers/common/markerService.zig").MarkerChangeEvent;
const MarkerDecorationsService = @import("../vs/editor/common/services/markerDecorationsService.zig").MarkerDecorationsService;
const markers_mod = @import("../vs/platform/markers/common/markers.zig");
const SnippetCompletionProvider = @import("../vs/workbench/contrib/snippets/browser/snippetCompletionProvider.zig").SnippetCompletionProvider;
const WordBasedCompletionProvider = @import("../vs/editor/contrib/suggest/browser/wordBasedSuggestions.zig").WordBasedCompletionProvider;
const Position = @import("../vs/editor/common/core/position.zig").Position;
const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
const EOL = @import("../vs/editor/common/core/misc/eolCounter.zig").EOL;
const encoding_mod = @import("../vs/workbench/services/textfile/common/encoding.zig");
const SearchOption = @import("../vs/workbench/contrib/search/browser/searchWidget.zig").Option;
const terminal_service_mod = @import("../vs/workbench/contrib/terminal/browser/terminalService.zig");
const terminal_configuration = @import("../vs/workbench/contrib/terminal/common/terminalConfiguration.zig");
const terminal_actions = @import("../vs/workbench/contrib/terminal/browser/terminalActions.zig");
const terminal_common = @import("../vs/workbench/contrib/terminal/common/terminal.zig");
const terminal_panel = @import("../vs/workbench/contrib/terminal/browser/terminalTabbedView.zig");
const terminal_tabs = @import("../vs/workbench/contrib/terminal/browser/terminalTabsList.zig");
const terminal_input_mod = @import("../vs/workbench/contrib/terminal/browser/terminalInput.zig");
const diff_widget_mod = @import("../vs/editor/browser/widget/diffEditor/diffEditorWidget.zig");
const git_model_mod = @import("../extensions/git/src/model.zig");
const git_mod = @import("../extensions/git/src/git.zig");
const scm_contribution = @import("../vs/workbench/contrib/scm/browser/scm.contribution.zig");
const SCMContribution = scm_contribution.SCMContribution;
const extensions_workbench_service = @import("../vs/workbench/contrib/extensions/browser/extensionsWorkbenchService.zig");
const extensions_views = @import("../vs/workbench/contrib/extensions/browser/extensionsViews.zig");
const extensions_viewlet = @import("../vs/workbench/contrib/extensions/browser/extensionsViewlet.zig");
const extensions_view_host = @import("extensionsViewHost.zig");
const scm_common = @import("../vs/workbench/contrib/scm/common/scm.zig");
const repository_mod = @import("../extensions/git/src/repository.zig");
const scm_view_mod = @import("../vs/workbench/contrib/scm/browser/scmViewPane.zig");
const scm_history_view_mod = @import("../vs/workbench/contrib/scm/browser/scmHistoryViewPane.zig");
const scm_common_history = @import("../vs/workbench/contrib/scm/common/history.zig");
const view_container_model_mod = @import("../vs/workbench/services/views/common/viewContainerModel.zig");
const view_pane_container_mod = @import("../vs/workbench/browser/parts/views/viewPaneContainer.zig");
const storage_mod = @import("../vs/platform/storage/common/storage.zig");
const TerminalService = terminal_service_mod.TerminalService;

pub const TabKeyResult = enum { unhandled, handled, quit };
pub const SplitDirection = grid_mod.Orientation;
/// Target selector shared by the move/copy editor and group commands, port of
/// upstream `SelectedEditorsMoveCopyArguments.to`.
pub const GroupLocation = editor_groups.GroupLocation;
pub const Focus = enum { editor, sidebar, statusbar, breadcrumbs, terminal, problems, bulk_edit, output };

/// Handles for the context keys the workbench maintains. User keybindings use
/// them in `when` clauses; keys the terminal cannot know stay undefined, which
/// evaluates to false (e.g. `treeFindOpen`).
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

const LayoutNode = grid_mod.Node(*GroupPane);

/// One editor group in the terminal editor part: the ported group view holds
/// the group model, the tabs (views/controllers), the tab-strip hit cache and
/// the cell rectangle it occupies.
pub const GroupPane = editor_group_view.EditorGroupView(*Tab);

const editor_mod = @import("../vs/workbench/common/editor.zig");

const text_files = @import("../vs/workbench/services/textfile/common/textFileService.zig");

const context_menus = @import("../vs/platform/contextview/browser/contextMenuService.zig");
const Menu = context_menus.Menu;
const MenuAnchor = context_menus.Anchor;

pub const IWorkbenchOptions = workbench_core.IWorkbenchOptions;

const views_service = @import("../vs/workbench/services/views/common/viewsService.zig");

const ViewsService = @import("../vs/workbench/services/views/browser/viewsService.zig").ViewsService;
const ViewRegistration = @import("../vs/workbench/services/views/browser/viewsService.zig").ViewRegistration;

pub const TerminalWorkbench = struct {
    core: workbench_core.Workbench,
    previous_state: ?PreviousState,
    lists: @import("../vs/platform/list/browser/listService.zig").ListService,
    list_api: @import("../vs/platform/list/browser/listService.zig").IListService,
    host_service: @import("../vs/workbench/services/host/browser/browserHostService.zig").BrowserHostService,
    host_api: @import("../vs/workbench/services/host/browser/host.zig").IHostService,
    storage_api: storage_mod.IStorageService,
    code_editors: CodeEditorService,
    word_highlight_session: @import("../vs/editor/contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterSession,
    window_views: ViewsService,
    views_api: views_service.IViewsService,
    code_editor_api: code_editor_service.ICodeEditorService,
    editors: editor_service_mod.EditorService,
    diff_commands: @import("../vs/workbench/browser/parts/editor/diffEditorCommandsService.zig").DiffEditorCommandsService,
    diff_commands_api: @import("../vs/workbench/browser/parts/editor/diffEditorCommandsService.zig").IDiffEditorCommandsService,
    editor_api: @import("../vs/workbench/services/editor/common/editorService.zig").IEditorService,
    preferences: @import("../vs/workbench/services/preferences/browser/preferencesService.zig").PreferencesService,
    preferences_api: @import("../vs/workbench/services/preferences/common/preferences.zig").IPreferencesService,
    editor_groups_api: editor_groups.IEditorGroupsService,
    allocator: Allocator,
    view_factory: @import("../vs/workbench/browser/parts/editor/editorPane.zig").EditorViewFactory,
    io: Io,
    /// Window-owned async workflows suspend on the serial WindowIo runtime.
    /// Its separate threaded backend handles detached file/process/CPU work;
    /// the terminal's synchronous/startup Io is borrowed from the host.
    worker_io_state: Io.Threaded,
    worker_io: Io,
    async_io_state: ui.WindowIo,
    async_io: Io,
    disk_files: @import("../vs/platform/files/common/fileService.zig").DiskFileService,
    text_file_service: text_files.TextFileService,
    resource_file_service: @import("../vs/platform/files/common/fileService.zig").ProviderFileService,
    disk_resource_provider: @import("../vs/platform/files/node/diskFileSystemProvider.zig").DiskFileSystemProvider,
    disk_resource_registration: @import("../vs/base/common/lifecycle.zig").IDisposable,
    extension_logger_service: @import("../vs/platform/log/common/fileLog.zig").FileLoggerService,
    output_service: @import("../vs/workbench/contrib/output/browser/outputServices.zig").OutputService,
    output_view: ?@import("../vs/workbench/contrib/output/browser/outputView.zig").OutputViewPane,
    file_service_api: @import("../vs/platform/files/common/files.zig").IFileService,
    working_copy_file_service: @import("../vs/workbench/services/workingCopy/common/workingCopyFileService.zig").WorkingCopyFileService,
    working_copy_file_api: @import("../vs/workbench/services/workingCopy/common/workingCopyFileService.zig").IWorkingCopyFileService,
    text_file_model_manager: @import("../vs/workbench/services/textfile/common/textFileEditorModelManager.zig").TextFileEditorModelManager,
    text_model_resolver: @import("../vs/workbench/services/textmodelResolver/common/textModelResolverService.zig").TextModelResolverService,
    text_model_api: @import("../vs/editor/common/services/resolverService.zig").ITextModelService,
    bulk_edit_service: @import("../vs/workbench/contrib/bulkEdit/browser/bulkEditService.zig").BulkEditService,
    bulk_edit_api: @import("../vs/editor/browser/services/bulkEditService.zig").IBulkEditService,
    model_service_api: @import("../vs/editor/common/services/modelService.zig").IModelService,
    /// Native file opening and event-driven reload owner.
    editor_opening: editor_service_mod.EditorOpening,
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
    /// Port of the Extensions viewlet: its workbench service, mounted
    /// pane-composite container and the list view resolved by the refresh and
    /// clear-search commands through the views service.
    extensions_service: ?*extensions_workbench_service.ExtensionsWorkbenchService = null,
    extensions_view: ?*extensions_viewlet.ExtensionsViewPaneContainer = null,
    extensions_list: ?*extensions_views.ExtensionsListView = null,
    window_events: @import("../vs/base/common/windowDispatch.zig").Queue,
    search_window: search_view_mod.SearchWindow,
    layout: *Layout,
    activity_bar_part: ActivityBarPart,
    sidebar_part: SidebarPart,
    panel_part: PanelPart,
    pane_composite_service: @import("../vs/workbench/browser/parts/paneCompositePartService.zig").PaneCompositePartService,
    pane_composite_api: @import("../vs/workbench/services/panecomposite/browser/panecomposite.zig").IPaneCompositePartService,
    view_containers_registry: views_mod.ViewContainersRegistry,
    views_registry: views_mod.ViewsRegistry,
    view_descriptor_service: ViewDescriptorService,
    statusbar: StatusbarService,
    language_status: @import("../vs/workbench/services/languageStatus/common/languageStatusService.zig").LanguageStatusService,
    language_status_api: @import("../vs/workbench/services/languageStatus/common/languageStatusService.zig").ILanguageStatusService,
    language_status_contribution: ?*@import("../vs/workbench/contrib/languageStatus/browser/languageStatus.zig").LanguageStatusContribution,
    statusbar_api: statusbar_types.IStatusbarService,
    notification_storage: storage_mod.InMemoryStorageService,
    notification_service: *@import("../vs/workbench/services/notification/common/notificationService.zig").NotificationService,
    notification_api: @import("../vs/platform/notification/common/notification.zig").INotificationService,
    images: ui.image.Runtime,
    markdown_previews: MarkdownPreviewManager,
    group_actions: @import("../vs/workbench/browser/parts/editor/editorActions.zig").GroupActions,
    /// Desired OSC 22 mouse pointer shape for the next frame. Only the
    /// composited renderer writes it; pane surfaces resolve shapes but never
    /// emit them.
    pointer: ui.Pointer = .default,
    pointer_state: ui.pointer.State = .{},
    pointer_shapes: bool = false,
    media_status: ?*MediaPreviewStatus = null,
    multi_diff_sources: @import("../vs/workbench/contrib/multiDiffEditor/browser/multiDiffSourceResolverService.zig").MultiDiffSourceResolverService,
    multi_diff_sources_api: @import("../vs/workbench/contrib/multiDiffEditor/browser/multiDiffSourceResolverService.zig").IMultiDiffSourceResolverService,
    scm_multi_diff_resolvers: *@import("../vs/workbench/contrib/multiDiffEditor/browser/scmMultiDiffSourceResolver.zig").ScmMultiDiffSourceResolverContribution,
    activity_service: ActivityService,
    editor_status: ?*EditorStatus = null,
    status_hint_accessor: ?EntryAccessor = null,
    /// Stable storage for the transient "Opening ..." status hint; the
    /// status-bar entry keeps the slice.
    status_hint_buf: [256]u8 = undefined,
    /// Branch-aware placeholder for the Source Control commit input.
    markers_status: ?*MarkersStatusBar = null,
    problems_view: ?MarkersView = null,
    bulk_edit_preview: ?BulkEditPane = null,
    bulk_edit_preview_contribution: ?BulkEditPreviewContribution = null,
    marker_listener: ?Emitter(MarkerChangeEvent).ListenerId = null,
    range_highlights: ?*RangeHighlightDecorations = null,
    workspace: *WorkspaceContextService,
    configuration: ?*ConfigurationService,
    configuration_migrations: @import("../vs/workbench/common/configuration.zig").ConfigurationMigrationWorkbenchContribution,
    configuration_binding: configuration_mod.ConfigurationServiceBinding,
    editor_configuration: @import("../vs/workbench/browser/parts/editor/textEditor.zig").TextEditorConfiguration,
    configured_languages: @import("../vs/workbench/services/language/common/languageService.zig").ConfiguredLanguageAssociations,
    configuration_api: @import("../vs/platform/configuration/common/configuration.zig").IConfigurationService,
    environment_api: @import("../vs/workbench/services/environment/common/environmentService.zig").IWorkbenchEnvironmentService,
    settings_watcher: ?*SettingsWatcher = null,
    /// Window file service shared by workspace and configuration watchers.
    file_watcher_service: ?*FileWatcherService = null,
    /// Port of the `workspaceWatcher.ts` contribution. Instantiated by the
    /// upstream `AfterRestored` phase, after the first frame.
    workspace_watcher: ?*WorkspaceWatcher = null,
    contributions: contributions_mod.WorkbenchContributions,
    lifecycle: @import("../vs/workbench/services/lifecycle/common/lifecycleService.zig").LifecycleService,
    user_settings_paths: []const []const u8,
    history: HistoryService,
    view_state_storage: ?view_container_model_mod.ViewDescriptorsState = null,
    sidebar_action_anchor: ?MenuAnchor = null,
    commands: CommandRegistry,
    working_copy_service: WorkingCopyService,
    tab_service: ?*keybinding_service.KeybindingService,
    tab_command_result: ?TabKeyResult = null,
    global_service: ?*keybinding_service.KeybindingService,
    context_keys: ?*context_key_mod.ContextKeyService,
    tab_focus: @import("../vs/editor/browser/config/tabFocus.zig").TabFocus,
    configuration_context: @import("../vs/platform/contextkey/browser/contextKeyService.zig").ConfigAwareContextValuesContainer,
    workbench_context: @import("../vs/workbench/browser/contextkeys.zig").WorkbenchContextKeysHandler,
    terminal_context: @import("../vs/workbench/contrib/terminal/browser/terminalContextKeys.zig").TerminalContextKeysHandler,
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
    quick_input_api: @import("../vs/platform/quickinput/common/quickInput.zig").IQuickInputService,
    simple_browser: SimpleBrowserManager,
    outline_service: OutlineService,
    services: ServiceCollection,
    instantiation: *InstantiationService,
    layout_api: layout_service_mod.IWorkbenchLayoutService,
    lifecycle_api: lifecycle_mod.ILifecycleService,
    /// Terminal Outline side panel (`outline` view container).
    outline_view: ?*OutlinePane = null,
    breadcrumbs: breadcrumbs_control_mod.BreadcrumbsControlCollection,
    home_path: ?[]u8 = null,
    symbol_navigation: go_to_commands.SymbolNavigationActionHost,
    symbol_quick_access: goto_symbol_quick_access.GotoSymbolQuickAccessProvider,
    builtin_host: *@import("../vs/workbench/api/browser/builtinExtensionHost.zig").BuiltinExtensionHost,
    references_view_registered: bool,
    references_view: @import("../extensions/references-view/referencesView.zig").SymbolsTree,
    frame_scheduler: ?struct {
        context: *anyopaque,
        request: *const fn (*anyopaque) void,
    } = null,
    context_menu_service: context_menus.ContextMenuService,
    accessible_view: @import("../vs/workbench/contrib/accessibility/browser/accessibleView.zig").AccessibleViewService,
    accessible_view_api: @import("../vs/platform/accessibility/browser/accessibleView.zig").IAccessibleViewService,
    clipboard_service: @import("clipboardService.zig").ClipboardService,
    clipboard_api: @import("../vs/platform/clipboard/common/clipboardService.zig").IClipboardService,
    context_menu_api: context_menus.IContextMenuService,
    action_widget_service: @import("../vs/platform/actionWidget/browser/actionWidget.zig").ActionWidgetService,
    action_widget_api: @import("../vs/platform/actionWidget/browser/actionWidget.zig").IActionWidgetService,
    sidebar_menus: sidebar_part_mod.SidebarViewMenus,
    editor_tab_menus: @import("../vs/workbench/browser/parts/editor/editorTabsControl.zig").EditorTabsControl,
    menu_service: @import("../vs/platform/actions/common/menuService.zig").MenuService,
    hovered_tab: ?*Tab = null,
    hovered_pane: ?*GroupPane = null,
    hovered_title_action_pane: ?*GroupPane = null,
    hovered_title_toolbar_id: ?[]const u8 = null,
    /// Pointer capture for the side-bar divider drag.
    hovered_sash: ?union(enum) { workbench: WorkbenchGrid.Sash, editor: *LayoutNode } = null,
    declarative: ?*const extensions_registry.Registry = null,
    json_client: ?*json_language.Client = null,
    language_features: ?*LanguageFeaturesService = null,
    marker_service: ?*MarkerService = null,
    marker_decorations: ?*MarkerDecorationsService = null,
    marker_navigation: ?@import("../vs/editor/contrib/gotoError/browser/markerNavigationService.zig").MarkerNavigationService = null,
    marker_navigation_api: ?@import("../vs/editor/contrib/gotoError/browser/markerNavigationService.zig").IMarkerNavigationService = null,
    snippet_provider: SnippetCompletionProvider,
    snippet_registration: ?IDisposable = null,
    word_completion_provider: ?*WordBasedCompletionProvider = null,
    word_completion_registration: ?IDisposable = null,
    textual_highlight_feature: ?*@import("../vs/editor/contrib/wordHighlighter/browser/textualHighlightProvider.zig").TextualMultiDocumentHighlightFeature = null,
    outline_creator: ?DocumentSymbolsOutlineCreator = null,
    code_lens_cache: ?*@import("../vs/editor/contrib/codelens/browser/codeLensCache.zig").CodeLensCache = null,
    focus: Focus = .editor,
    focus_subscriptions: [5]?@import("../vs/base/common/event.zig").SignalSubscription = .{ null, null, null, null, null },
    terminal_focus_subscription: ?@import("../vs/base/common/event.zig").SignalSubscription = null,
    is_pasting: bool = false,
    terminal_service: ?*TerminalService = null,
    terminal_input: terminal_input_mod.Encoder = .{},
    terminal_tabbed_view: terminal_panel.TerminalTabbedView = .{},
    suppress_global_command: bool = false,
    git_model: git_model_mod.Model,
    git_file_provider: @import("../extensions/git/src/fileSystemProvider.zig").GitFileSystemProvider,
    github_publish: @import("../extensions/github/src/commands.zig").PublishCommand,
    git_commands: @import("../extensions/git/src/commands.zig").CommandContribution,
    scm: SCMContribution,
    /// Set when the quit confirmation commits to closing the window.
    quit_requested: bool = false,
    /// The modal save confirmation, if one is open.
    dialog_service: @import("../vs/workbench/services/dialogs/common/dialogService.zig").DialogService,
    dialog_handler: *@import("../vs/workbench/browser/parts/dialogs/dialog.web.contribution.zig").DialogHandlerContribution,
    dialog_api: dialogs.IDialogService,

    pub const PreviousState = struct {
        data: ?editor_groups.SerializedEditorPart = null,
        registry: *editor_factory.EditorFactoryRegistry,
    };

    /// Constructs the window. The host owns the surface and the option slices
    /// through startup. Service instances supplied by the host remain borrowed.
    pub fn init(allocator: Allocator, io: Io, view_factory: @import("../vs/workbench/browser/parts/editor/editorPane.zig").EditorViewFactory, surface: *ui.Surface, services: *ServiceCollection, options: IWorkbenchOptions, state: ?PreviousState) !*TerminalWorkbench {
        const parent = surface.document().root orelse return error.MissingWorkbenchParent;
        const self = try allocator.create(TerminalWorkbench);
        errdefer allocator.destroy(self);

        self.* = undefined;
        self.previous_state = state;
        const previous_editor_state = if (state) |previous| previous.data else null;
        self.references_view_registered = false;
        self.allocator = allocator;
        self.view_factory = view_factory;
        self.io = io;
        self.worker_io_state = Io.Threaded.init(allocator, .{
            .async_limit = .unlimited,
            .environ = asyncEnviron(),
        });
        errdefer self.worker_io_state.deinit();
        self.worker_io = self.worker_io_state.io();
        self.async_io_state = try ui.WindowIo.init(allocator, self.worker_io);
        errdefer self.async_io_state.deinit();
        self.async_io = self.async_io_state.io();
        self.disk_files = .init(allocator, self.worker_io);
        errdefer self.disk_files.deinit();
        self.text_file_service = .init(allocator, &self.disk_files);
        errdefer self.text_file_service.deinit();
        self.editor_surface = surface;
        self.cols = surface.document().cols;
        self.tab_service = null;
        self.global_service = null;
        self.context_keys = null;
        self.tab_focus = .init(allocator);
        errdefer self.tab_focus.deinit();
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
        self.focus_subscriptions = .{ null, null, null, null, null };
        self.suppress_global_command = false;
        self.git_model = git_model_mod.Model.init(allocator);
        self.scm = SCMContribution.init(allocator);
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
        self.extensions_service = null;
        self.extensions_view = null;
        self.extensions_list = null;
        self.window_events = .{ .io = self.async_io, .scheduler = &self.async_io_state, .window_events = .init(allocator) };
        errdefer self.window_events.deinitWindowEvents();
        self.resource_file_service = .init(allocator);
        errdefer self.resource_file_service.deinit();
        self.file_service_api = self.resource_file_service.interface();
        self.extension_logger_service = .init(allocator, self.file_service_api);
        errdefer self.extension_logger_service.deinit();
        self.disk_resource_provider = .init(allocator, self.worker_io);
        errdefer self.disk_resource_provider.deinit();
        self.disk_resource_registration = try self.file_service_api.registerProvider("file", self.disk_resource_provider.interface());
        errdefer self.disk_resource_registration.dispose();
        self.output_service = .init(allocator, self.file_service_api, &self.extension_logger_service);
        errdefer self.output_service.deinit();
        try self.output_service.attach();
        self.output_view = null;
        self.working_copy_file_service = .init(allocator, self.file_service_api, &self.working_copy_service);
        errdefer self.working_copy_file_service.deinit();
        self.working_copy_file_api = self.working_copy_file_service.interface();
        self.text_model_resolver = .init(allocator, self.worker_io, &self.window_events);
        self.text_model_resolver.text_files = &self.text_file_service;
        errdefer self.text_model_resolver.deinit();
        try self.text_model_resolver.bindFileService(self.file_service_api);
        _ = try self.text_model_resolver.undoRedoStore();
        self.text_model_api = self.text_model_resolver.interface();
        const FileModelAccessAdapter = @import("../vs/workbench/services/textmodelResolver/common/textModelResolverService.zig").TextModelResolverService.FileModelAccessAdapter;
        self.text_file_model_manager = .init(allocator, self.file_service_api, (FileModelAccessAdapter{ .service = &self.text_model_resolver }).interface());
        errdefer self.text_file_model_manager.deinit();
        try self.text_file_model_manager.bind(self.working_copy_file_api);
        self.bulk_edit_service = .{ .allocator = allocator, .resolver_service = self.text_model_api, .working_copy_service = &self.working_copy_service, .undo_redo_service = &self.text_model_resolver.undo_store.?.service, .file_services = .{ .files = self.file_service_api, .working_copies = self.working_copy_file_api, .undo_redo = &self.text_model_resolver.undo_store.?.service } };
        self.bulk_edit_api = self.bulk_edit_service.interface();
        self.model_service_api = self.text_model_resolver.modelService();
        self.git_file_provider = .init(allocator, &self.git_model, self.worker_io);
        errdefer self.git_file_provider.deinit();
        self.git_file_provider.setRepositoryDiscovery(.{ .context = self, .open = discoverGitResourceRepository, .capture = captureGitResourceRepository, .publish = publishGitResourceRepository });
        try self.git_file_provider.register(self.file_service_api, .{
            .context = &self.text_model_resolver,
            .is_open = struct {
                fn isOpen(context: *anyopaque, path: []const u8) bool {
                    const resolver: *@import("../vs/workbench/services/textmodelResolver/common/textModelResolverService.zig").TextModelResolverService = @ptrCast(@alignCast(context));
                    return resolver.hasResolvedModel(.{ .scheme = "file", .path = .{ .raw = path } });
                }
            }.isOpen,
        });
        self.user_keybindings = try user_keybindings_mod.UserKeybindingsLoader.create(allocator, io, self.async_io, &self.window_events);
        errdefer self.user_keybindings.destroy();
        _ = try self.user_keybindings.on_did_change.listen(self, onUserKeybindingsChanged);
        self.search_window = undefined;
        self.search_window.view = null;
        self.search_window.service = null;
        try self.initShellModels(parent, options, previous_editor_state != null);
        errdefer self.deinitShellModels();
        self.outline_service = OutlineService.init(allocator);
        errdefer self.outline_service.deinit();
        self.home_path = readHomePath(allocator);
        errdefer if (self.home_path) |path| allocator.free(path);
        self.frame_scheduler = null;
        self.context_menu_service = .init(allocator, self, reportMenuError);
        errdefer self.context_menu_service.deinit();
        self.action_widget_service = .{ .allocator = allocator, .context_menu = self.context_menu_service.interface() };
        self.action_widget_api = self.action_widget_service.interface();
        errdefer self.action_widget_service.deinit();
        self.accessible_view = .init(allocator, io, view_factory, .{ .context = self, .request_frame = requestWorkbenchFrame, .lookup_keybinding = accessibilityKeybindingLabel, .visibility_changed = accessibilityVisibilityChanged });
        errdefer self.accessible_view.deinit();
        try @import("../vs/workbench/workbench.common.main.zig").registerAccessibleViews(&self.accessible_view.registry);
        self.accessible_view_api = self.accessible_view.interface();
        self.clipboard_service = .init(allocator);
        errdefer self.clipboard_service.deinit();
        self.clipboard_api = self.clipboard_service.interface();
        self.hovered_tab = null;
        self.hovered_pane = null;
        self.declarative = null;
        self.json_client = null;
        self.language_features = null;
        self.marker_service = null;
        self.marker_decorations = null;
        self.marker_navigation = null;
        self.marker_navigation_api = null;
        self.snippet_provider = SnippetCompletionProvider.init(allocator, io);
        self.snippet_registration = null;
        self.word_completion_provider = null;
        self.word_completion_registration = null;
        self.textual_highlight_feature = null;
        self.outline_creator = null;
        self.outline_view = null;
        self.workspace = try WorkspaceContextService.initEmpty(allocator, "workspace");
        errdefer self.workspace.deinit();
        self.configuration = null;
        self.configuration_migrations = .init(allocator);
        errdefer self.configuration_migrations.deinit();
        try @import("../vs/workbench/workbench.common.main.zig").registerConfigurationMigrations(&self.configuration_migrations.registry);
        self.configuration_binding = .init(allocator);
        errdefer self.configuration_binding.deinit();
        self.settings_watcher = null;
        self.file_watcher_service = null;
        self.workspace_watcher = null;
        self.contributions = contributions_mod.WorkbenchContributions.init(allocator);
        self.lifecycle = .init(allocator);
        errdefer self.lifecycle.deinit();
        errdefer self.contributions.deinit();
        try self.contributions.register(.after_restored, self, initAfterRestoredWorkspaceWatcher);
        try self.contributions.register(.eventually, &self.configuration_migrations, @TypeOf(self.configuration_migrations).start);
        self.user_settings_paths = try dupeOwnedPaths(allocator, options.initial_user_settings_paths);
        errdefer freeOwnedPaths(allocator, self.user_settings_paths);

        self.service = if (previous_editor_state) |previous|
            try editor_groups.EditorGroupsService.prepareSerializedPart(allocator, previous, .{})
        else
            try editor_groups.EditorGroupsService.init(allocator, .{});
        errdefer self.service.deinit();
        self.part = try editor_part.EditorPart(GroupPane).initWithState(allocator, self.service, if (previous_editor_state) |previous| previous.serialized_grid else null);
        self.code_editors = .init(allocator, self.part);
        self.code_editor_api = self.code_editors.interface();
        self.word_highlight_session = .init(allocator);
        self.word_highlight_session.editors = self.code_editor_api;
        errdefer {
            self.part.deinit();
            self.word_highlight_session.deinit();
            self.code_editors.deinit();
        }
        self.configured_languages = .{ .allocator = allocator, .part = self.part, .configuration = &self.configuration_binding };
        try self.configured_languages.attach();
        errdefer self.configured_languages.deinit();
        self.editor_configuration = .{ .part = self.part, .configuration = &self.configuration_binding, .theme = &self.theme_palette, .tab_focus = &self.tab_focus };
        try self.editor_configuration.attach();
        errdefer self.editor_configuration.deinit();
        self.markdown_previews = .{
            .allocator = allocator,
            .part = self.part,
            .configuration = &self.configuration,
            .theme_palette = &self.theme_palette,
            .copy_host = self.copyEditorHost(),
            .layout = struct {
                fn run(context: *anyopaque) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.layoutAll();
                }
            }.run,
            .focus_editor = focusWindowEditor,
        };
        errdefer self.markdown_previews.deinit();
        self.group_actions = .{
            .part = self.part,
            .transfer = self.groupTransferHost(),
            .configuration = &self.configuration,
            .close_host = self.closeEditorHost(),
            .dialog_service = &self.dialog_api,
            .history = &self.history,
            .report_status = struct {
                fn report(context: *anyopaque, message: []const u8) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.setStatusHint("{s}", .{message});
                }
            }.report,
        };
        self.editor_tab_menus = .{
            .allocator = allocator,
            .groups = &self.group_actions,
            .menus = &self.menu_service,
            .context_menu = &self.context_menu_service,
            .context_keys = &self.core.context_keys,
            .host = .{
                .context = self,
                .request_frame = struct {
                    fn run(context: *anyopaque) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.requestFrame();
                    }
                }.run,
                .move_terminal_to_panel = struct {
                    fn run(context: *anyopaque, pane: *GroupPane, tab: *Tab) !void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        try host.moveTerminalToPanel(pane, tab);
                    }
                }.run,
                .rename_terminal = struct {
                    fn run(context: *anyopaque, tab: *Tab) !void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        if (tab.terminalInstance()) |instance| try host.showTerminalRename(instance);
                    }
                }.run,
            },
        };
        self.range_highlights = try RangeHighlightDecorations.create(allocator, @import("../vs/workbench/browser/codeeditor.zig").Host.forEditorPart(self.part));
        self.part.attachWindow(&self.window_events);
        try self.part.base.register(self.layout.interface());
        self.frame = try ui.Frame.init(allocator, self.cols, self.rows);
        errdefer self.frame.deinit();
        try self.breadcrumbs.init(allocator, self.io, self.part, self.workspace, &self.outline_service, self.home_path, .{
            .context = self,
            .file_icon_theme = struct {
                fn run(context: *anyopaque) file_icon.FileIconThemeData {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    return host.getFileIconTheme();
                }
            }.run,
            .open_file = struct {
                fn run(context: *anyopaque, path: []const u8) anyerror!void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.requestOpenPath(path);
                }
            }.run,
            .request_render = requestWorkbenchFrame,
            .focus_editor = breadcrumbFocusEditor,
            .focus_breadcrumbs = struct {
                fn run(context: *anyopaque) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.setFocus(.breadcrumbs);
                    host.statusbar.main_part.clearFocus();
                    if (host.search_window.view) |view| view.blur();
                }
            }.run,
            .layout_changed = struct {
                fn run(context: *anyopaque) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.layoutAll();
                }
            }.run,
        });
        errdefer self.breadcrumbs.deinit();
        self.editor_drop_target.init(allocator, self.part, &self.window_events, &self.configuration, &self.theme_palette, &self.frame, &self.pointer, .{
            .context = self,
            .terminal_panel_rect = struct {
                fn run(context: *anyopaque) ?ui.Rect {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    return if (host.terminalPanelActive()) host.geometry().panelRect() else null;
                }
            }.run,
            .clear_hover = struct {
                fn run(context: *anyopaque) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.clearTabHover();
                }
            }.run,
            .activate_index = struct {
                fn run(context: *anyopaque, index: usize) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    try host.activateIndex(index);
                }
            }.run,
            .copy_editor = struct {
                fn run(context: *anyopaque, pane: *GroupPane, tab: *Tab, open_options: group_mod.EditorOpenOptions) !*Tab {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    return host.copyTabIntoPaneWithOptions(pane, tab, open_options);
                }
            }.run,
            .move_editor = struct {
                fn run(context: *anyopaque, source: *GroupPane, target: *GroupPane, tab: *Tab, open_options: group_mod.EditorOpenOptions) !*Tab {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    return host.moveTabToPaneWithOptions(source, target, tab, open_options);
                }
            }.run,
            .move_terminal_to_panel = struct {
                fn run(context: *anyopaque, pane: *GroupPane, tab: *Tab) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    try host.moveTerminalToPanel(pane, tab);
                }
            }.run,
            .destroy_pane = struct {
                fn run(context: *anyopaque, pane: *GroupPane) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.destroyPane(pane);
                }
            }.run,
            .collapse_empty_pane = struct {
                fn run(context: *anyopaque, pane: *GroupPane) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.collapseEmptyPane(pane);
                }
            }.run,
            .focus_pane = struct {
                fn run(context: *anyopaque, pane: *GroupPane) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    try host.focusPane(pane);
                }
            }.run,
        });
        errdefer self.editor_drop_target.deinit();
        self.services = .init(allocator);
        std.mem.swap(ServiceCollection, services, &self.services);
        errdefer self.services.deinit();
        try self.initQuickAccess();
        errdefer self.text_model_resolver.bindWorkingCopyService(null) catch {};
        try self.text_model_resolver.bindWorkingCopyService(&self.working_copy_service);
        self.git_commands = .{
            .allocator = allocator,
            .model = &self.git_model,
            .io = self.io,
            .snapshot_io = self.worker_io,
            .quick_input = self.quick_access.inputService(),
            .configuration = &self.configuration_api,
            .editors = &self.editor_api,
            .dialogs = &self.dialog_api,
            .publish_arena = std.heap.ArenaAllocator.init(allocator),
            .host = .{
                .context = self,
                .focus_editor = scmFocusEditor,
                .refresh_resources = scmRefresh,
                .did_run_remote_action = onScmRemoteAction,
                .request_frame = requestWorkbenchFrame,
                .files_changed = struct {
                    fn run(context: *anyopaque, changes: []const @import("../vs/platform/files/common/files.zig").FileChange) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.handleFileChanges(changes);
                    }
                }.run,
                .report_status = scmViewStatus,
                .working_text = struct {
                    fn get(context: *anyopaque, allocator_: Allocator, path: []const u8) !?[]u8 {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        const input = host.findOpenInput(path) orelse return null;
                        var value = try input.editor.model.getValue(.TextDefined, true);
                        defer value.deinit();
                        return try allocator_.dupe(u8, value.items);
                    }
                }.get,
                .has_diff = struct {
                    fn get(context: *anyopaque, path: []const u8, left: []const u8, right: []const u8) bool {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        return (editor_service_mod.EditorService{ .part = host.part }).findDiffTab(path, left, right) != null;
                    }
                }.get,
                .open_snapshot = struct {
                    fn open(context: *anyopaque, path: []const u8, source: @import("../vs/editor/browser/widget/diffEditor/diffProviderFactoryService.zig").SnapshotSource, left: []const u8, right: []const u8) !void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        try host.openSnapshotDiff(path, source, left, right);
                    }
                }.open,
                .refresh = struct {
                    fn refresh(context: *anyopaque) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.refreshGitStatus();
                        if (host.scm.history) |view| {
                            view.outdated = false;
                            view.refresh(.reload) catch {};
                        }
                    }
                }.refresh,
                .commit_input = struct {
                    fn commit(context: *anyopaque) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        if (host.scm.changes) |view| _ = view.commitInput();
                    }
                }.commit,
                .selected_resource = struct {
                    fn selected(context: *anyopaque) ?*scm_common.ISCMResource {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        const view = host.scm.changes orelse return null;
                        return view.selectedResource();
                    }
                }.selected,
                .open_active_diff = struct {
                    fn open(context: *anyopaque) !void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        const tab = host.activeTab() orelse return;
                        const diff = tab.diff orelse return;
                        try host.openPath(diff.model.modified_path);
                    }
                }.open,
            },
        };
        self.editor_opening = .{
            .allocator = allocator,
            .part = self.part,
            .group_actions = &self.group_actions,
            .io = self.io,
            .view_factory = self.view_factory,
            .images = &self.images,
            .window_events = &self.window_events,
            .text_file_service = &self.text_file_service,
            .text_model_resolver = &self.text_model_resolver,
            .history = &self.history,
            .declarative = &self.declarative,
            .json_client = &self.json_client,
            .language_features = &self.language_features,
            .reload_jobs = .init(allocator),
            .multi_diff_source_services = .{
                .configuration = &self.configuration_api,
                .resolver = self.multi_diff_sources_api,
                .storage = &self.storage_api,
                .workspace = self.workspace,
                .lists = &self.lists,
                .menus = &self.menu_service,
                .context_keys = &self.core.context_keys,
                .context_menu = &self.context_menu_api,
            },
            .host = .{
                .context = self,
                .configure_editor = struct {
                    fn configure(context: *anyopaque, editor: *Editor) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.ensureConfiguration() catch {};
                        editor.document.text_file_service = &host.text_file_service;
                        editor.attachCodeEditorService(host.code_editor_api, &host.word_highlight_session) catch {};
                        host.configured_languages.applyToEditor(editor);
                        if (host.language_features) |features| editor.attachLanguageServices(features, host.marker_service, host.marker_decorations);
                    }
                }.configure,
                .configure_tab = struct {
                    fn configure(context: *anyopaque, tab: *Tab) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.editor_configuration.applyToTab(tab);
                        if (host.language_features) |features| tab.attachLanguageRegistry(features);
                        host.attachLanguageContributionServices(tab);
                        host.instantiation.invokeFunction(@import("../vs/workbench/workbench.common.main.zig").attachDiffEditorContributions, .{tab}) catch {};
                        tab.attachDiffActionServices(host.clipboard_api, host.context_menu_api);
                        if (tab.diff != null) {
                            tab.attachDiffGutterServices(&host.menu_service, host.core.context_keys.getContext(), host.context_menu_api);
                            if (host.language_features) |features| if (host.outline_creator) |creator| tab.attachDiffBreadcrumbs(features, creator.models);
                        }
                    }
                }.configure,
                .configure_diff_widget = struct {
                    fn configure(context: *anyopaque, widget: *@import("../vs/workbench/browser/parts/editor/editorPane.zig").DiffWidget) !void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.editor_configuration.applyToDiffWidget(widget);
                        if (widget.native_input_services == null) {
                            widget.attachNativeInputServices(try @import("../vs/workbench/browser/parts/editor/editorPane.zig").MultiDiffBindingServices.create(host.allocator, widget, &host.window_events));
                        }
                        host.attachMultiDiffLanguageServices(widget);
                        try host.instantiation.invokeFunction(@import("../vs/workbench/workbench.common.main.zig").attachDiffWidgetContributions, .{widget});
                        widget.attachActionServices(host.clipboard_api, host.context_menu_api);
                        try widget.attachGutterServices(&host.menu_service, host.core.context_keys.getContext(), host.context_menu_api);
                        if (host.language_features) |features| if (host.outline_creator) |creator| {
                            const factory = try @import("../vs/editor/contrib/diffEditorBreadcrumbs/browser/contribution.zig").Factory.create(host.allocator, features.interface(), creator.models);
                            try widget.attachBreadcrumbs(factory);
                        };
                    }
                }.configure,
                .dispose_diff_widget = struct {
                    fn dispose(context: *anyopaque, widget: *@import("../vs/workbench/browser/parts/editor/editorPane.zig").DiffWidget) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        if (host.context_keys != null) {
                            host.workbench_context.detachEditor(widget.original_editor);
                            host.workbench_context.detachEditor(widget.modified_editor);
                        }
                        if (host.editor_status) |status| {
                            status.detachDisposedEditor(widget.original_editor);
                            status.detachDisposedEditor(widget.modified_editor);
                        }
                        if (host.outline_view) |view| {
                            view.detachDisposedEditor(widget.original_editor);
                            view.detachDisposedEditor(widget.modified_editor);
                        }
                    }
                }.dispose,
                .register_working_copy = struct {
                    fn register(context: *anyopaque, tab: *Tab) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.registerWorkingCopy(tab);
                    }
                }.register,
                .change_working_copy = struct {
                    fn change(context: *anyopaque, editor: *Editor, add: bool) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        if (add) host.acquireWorkingEditor(editor) else host.releaseWorkingEditor(editor);
                    }
                }.change,
                .discard_tab = discardTransferPane,
                .request_close_editor = struct {
                    fn close(context: *anyopaque, group_id: editor_mod.GroupIdentifier, input: *EditorInput, preserve_focus: bool) !void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        const group = host.service.getGroup(group_id) orelse return;
                        const pane = host.part.viewForGroup(group) orelse return;
                        const tab = pane.tabForInput(input) orelse return;
                        try pane.closeEditorsWithOptions(&.{tab}, host.dialog_api, host.closeEditorHost(), .{ .preserve_focus = preserve_focus });
                    }
                }.close,
                .focus_editor = focusWindowEditor,
                .request_frame = requestWorkbenchFrame,
                .show_status = struct {
                    fn show(context: *anyopaque, message: []const u8) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.setStatusHint("{s}", .{message});
                    }
                }.show,
                .image_dimensions = struct {
                    fn dimensions(context: *anyopaque) editor_service_mod.EditorOpening.ImageDimensions {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        return .{ .width = host.cols, .height = host.editorContentHeight() };
                    }
                }.dimensions,
            },
        };
        try self.editor_opening.bindWorkingCopyFileService(self.working_copy_file_api, self.file_service_api);
        errdefer self.editor_opening.unbindWorkingCopyFileService();
        self.search_window = .{
            .lists = &self.lists,
            .allocator = allocator,
            .io = self.io,
            .part = self.part,
            .workspace = self.workspace,
            .configuration = &self.configuration,
            .editor_opening = &self.editor_opening,
            .activity_service = &self.activity_service,
            .title_pane = &self.sidebar_part.pane,
            .dialog_service = &self.dialog_service,
            .window = &self.window_events,
            .view_factory = self.view_factory,
            .host = .{
                .context = self,
                .ensure_configuration = struct {
                    fn run(context: *anyopaque) !void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        try host.ensureConfiguration();
                    }
                }.run,
                .configure_tab = struct {
                    fn run(context: *anyopaque, tab: *Tab) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.editor_configuration.applyToTab(tab);
                    }
                }.run,
                .update_focus = struct {
                    fn run(context: *anyopaque) !void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        try host.updatePartFocus();
                    }
                }.run,
                .layout = struct {
                    fn run(context: *anyopaque) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.layoutAll();
                    }
                }.run,
                .focus_editor = focusWindowEditor,
                .focus_result = struct {
                    fn run(context: *anyopaque) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.setFocus(.editor);
                    }
                }.run,
            },
        };
        self.search_window.bindEditorFactory();
        self.symbol_navigation = .{
            .window = &self.window_events,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .quick_input = self.quick_access.inputService(),
            .language_features = &self.language_features,
            .host = .{
                .context = self,
                .active_editor = navigationActiveEditor,
                .workspace_root = struct {
                    fn root(context: *anyopaque) ?[]const u8 {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        return host.workspaceFolderPath();
                    }
                }.root,
                .find_open_editor = struct {
                    fn find(context: *anyopaque, path: []const u8) ?*Editor {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        return if (host.findOpenInput(path)) |input| input.editor else null;
                    }
                }.find,
                .open_link = struct {
                    fn open(context: *anyopaque, link: languages.LocationLink) !void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        try host.navigateToLink(link);
                    }
                }.open,
            },
        };
        self.symbol_quick_access = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .quick_input = self.quick_access.inputService(),
            .language_features = &self.language_features,
            .host = .{
                .context = self,
                .active_editor = navigationActiveEditor,
                .outline_models = struct {
                    fn models(context: *anyopaque) ?*outline_model.OutlineModelService {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        return if (host.outline_creator) |creator| creator.models else null;
                    }
                }.models,
                .reveal_editor = struct {
                    fn reveal(context: *anyopaque) void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        host.focusEditor();
                    }
                }.reveal,
            },
        };
        return self;
    }

    pub fn startup(self: *TerminalWorkbench) !*InstantiationService {
        return self.core.startup(&self.services, .{
            .context = self,
            .part = self.part,
            .commands = &self.commands,
            .contributions = &self.contributions,
            .editor_factory_registry = if (self.previous_state) |previous| previous.registry else null,
            .lifecycle = &self.lifecycle,
            .notification_service = self.notification_service,
            .statusbar = &self.statusbar,
            .window = &self.window_events,
            .configuration = &self.configuration,
            .notification_host = .{
                .context = self,
                .request_frame = notificationFrame,
                .open_link = notificationOpenLink,
                .focus_editor = notificationFocusEditor,
            },
            .register_services = struct {
                fn run(context: *anyopaque) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    try host.registerNativeServices();
                }
            }.run,
            .register_commands = struct {
                fn run(context: *anyopaque) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    try host.registerActions();
                }
            }.run,
            .context_keys = struct {
                fn run(context: *anyopaque) !@import("../vs/platform/contextkey/common/contextkey.zig").IContextKeyService {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    if (host.user_settings_paths.len > 0) try host.ensureConfiguration();
                    return (try host.ensureContextKeys()).interface();
                }
            }.run,
            .register_listeners = struct {
                fn run(context: *anyopaque) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    try host.registerNativeListeners();
                }
            }.run,
            .restore_editors = struct {
                fn run(context: *anyopaque) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    try host.restoreEditors();
                }
            }.run,
            .layout = struct {
                fn run(context: *anyopaque) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.layoutAll();
                }
            }.run,
        });
    }

    fn notificationFrame(context: *anyopaque) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.requestFrame();
    }
    fn notificationFocusEditor(context: *anyopaque) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.focusEditor();
    }
    fn notificationOpenLink(context: *anyopaque, href: []const u8) !void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        if (std.mem.startsWith(u8, href, "command:")) {
            try self.commands.execute(href["command:".len..]);
        } else if (std.mem.startsWith(u8, href, "file://")) {
            try self.openPath(href["file://".len..]);
        } else _ = try @import("../vs/platform/opener/common/opener.zig").openExternal(self.allocator, self.io, href);
    }

    fn registerNativeListeners(self: *TerminalWorkbench) !void {
        _ = try self.dialog_api.on_will_show_dialog.listenSignal(self, onDialogStateChanged);
        _ = try self.dialog_api.on_did_show_dialog.listenSignal(self, onDialogStateChanged);
        _ = try self.part.on_did_focus.listen(self, onEditorPartFocus);
        _ = try self.part.on_did_add_group.listenSignal(self, onEditorGroupsChanged);
        _ = try self.part.on_did_move_group.listenSignal(self, onEditorGroupsChanged);
        _ = try self.part.on_did_change_group_maximized.listenSignal(self, onEditorGroupsChanged);
        try self.markdown_previews.registerListeners();
        try self.history.registerListeners(.{
            .context = self,
            .part = self.part,
            .io = self.io,
            .open_path = struct {
                fn run(context: *anyopaque, path: []const u8) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    try host.openPath(path);
                }
            }.run,
            .focus_editor = struct {
                fn run(context: *anyopaque) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.focusEditor();
                }
            }.run,
        });
        self.focus_subscriptions[0] = try self.service.on_did_active_editor_change.listenSignal(self, updatePartFocus);
        self.focus_subscriptions[1] = try self.service.on_did_visible_editors_change.listenSignal(self, updatePartFocus);
        self.focus_subscriptions[2] = try self.quick_input_api.on_show.listenSignal(self, updatePartFocus);
        self.focus_subscriptions[3] = try self.quick_input_api.on_hide.listenSignal(self, updatePartFocus);
        self.focus_subscriptions[4] = try self.activity_bar_part.on_did_change.listenSignal(self, updatePartFocus);
        _ = try self.layout.on_did_change.listen(self, onGridChanged);
        self.menu_service.useContextService(self.context_keys.?);
        try self.part.attachTitleMenus(.{ .menus = &self.menu_service, .parent_context = self.core.context_keys.getContext(), .context = self, .request_frame = requestWorkbenchFrame });
        errdefer self.part.disposeTitleMenus();
        try self.panel_part.attachTitleMenu(&self.menu_service, self.core.context_keys.getContext());
        try self.panel_part.attachViewTitleMenu(BulkEditPane.ID, BulkEditPane.title_menu_id, &self.menu_service, self.core.context_keys.getContext());
        _ = try self.panel_part.on_did_change.listenSignal(self, struct {
            fn run(host: *TerminalWorkbench) !void {
                host.requestFrame();
            }
        }.run);
        const editor_service = @import("../vs/workbench/services/editor/browser/editorService.zig").EditorService{ .part = self.part };
        if (self.editor_status) |status| try status.bindActiveEditor(editor_service);
        if (self.media_status) |status| try status.bindActiveEditor(editor_service);
    }

    fn registerNativeServices(self: *TerminalWorkbench) !void {
        _ = try self.services.set(@import("../vs/editor/browser/config/tabFocus.zig").tab_focus_id, &self.tab_focus);
        _ = try self.tab_focus.on_did_change_tab_focus.listen(self, onTabFocusChanged);
        self.context_menu_api = self.context_menu_service.interface();
        _ = try self.services.set(context_menus.context_menu_service_id, &self.context_menu_api);
        _ = try self.services.set(@import("../vs/platform/actionWidget/browser/actionWidget.zig").action_widget_service_id, &self.action_widget_api);
        _ = try self.services.set(@import("../vs/platform/clipboard/common/clipboardService.zig").clipboard_service_id, &self.clipboard_api);
        self.statusbar_api = self.statusbar.interface();
        _ = try self.services.set(statusbar_types.statusbar_service_id, &self.statusbar_api);
        self.sidebar_menus = .{
            .allocator = self.allocator,
            .sidebar = &self.sidebar_part,
            .descriptors = &self.view_descriptor_service,
            .context_menu = self.context_menu_api,
            .menus = &self.menu_service,
            .context_keys = &self.core.context_keys,
            .commands = &self.commands,
            .host = .{
                .context = self,
                .anchor = struct {
                    fn run(context: *anyopaque, id: []const u8) MenuAnchor {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        return host.sidebarMenuAnchor(id);
                    }
                }.run,
            },
        };
        _ = try self.services.set(sidebar_part_mod.sidebar_view_menus_id, &self.sidebar_menus);
        self.list_api = self.lists.interface();
        _ = try self.services.set(@import("../vs/platform/list/browser/listService.zig").list_service_id, &self.list_api);

        self.lifecycle_api = self.lifecycle.interface();
        self.layout_api = self.layout.interface();
        self.pane_composite_service = .{
            .sidebar = &self.sidebar_part,
            .panel = &self.panel_part,
            .host = .{ .context = self, .open = openNativePaneComposite },
        };
        self.pane_composite_api = self.pane_composite_service.interface();
        _ = try self.services.set(@import("../vs/workbench/services/panecomposite/browser/panecomposite.zig").pane_composite_part_service_id, &self.pane_composite_api);
        self.layout.pane_composite_service = self.pane_composite_api;
        self.layout.view_descriptor_service = &self.view_descriptor_service;
        self.window_views.attach(self.pane_composite_api, self.layout_api);
        for ([_]ViewRegistration{
            ViewRegistration.valueSlot(MarkersView, &self.problems_view, .{ .container = PROBLEMS_CONTAINER_ID }),
            ViewRegistration.valueSlot(@import("../vs/workbench/contrib/output/browser/outputView.zig").OutputViewPane, &self.output_view, .{ .container = @import("../vs/workbench/services/output/common/output.zig").OUTPUT_VIEW_ID }),
            ViewRegistration.valueSlot(BulkEditPane, &self.bulk_edit_preview, .{ .container = BulkEditPane.ID }),
            ViewRegistration.pointerSlot(SearchView, &self.search_window.view, .{ .container = "search" }),
            ViewRegistration.pointerSlot(OutlinePane, &self.outline_view, .{ .descriptor = "outline" }),
            ViewRegistration.pointerSlot(scm_view_mod.SCMViewPane, &self.scm.changes, .{ .descriptor = "changes" }),
            ViewRegistration.pointerSlot(scm_history_view_mod.SCMHistoryViewPane, &self.scm.history, .{ .descriptor = "graph" }),
            ViewRegistration.pointerSlot(extensions_views.ExtensionsListView, &self.extensions_list, .{ .container = extensions_views.ExtensionsListView.ID }),
        }) |registration| try self.window_views.registerView(registration);
        self.views_api = self.window_views.interface();
        self.output_view = .{ .service = &self.output_service, .views = self.views_api, .pane = &self.panel_part.pane, .layout = self.layout_api, .host = .{ .context = self, .changed = outputViewChanged } };
        errdefer {
            self.output_view.?.deinit();
            self.output_view = null;
        }
        try self.output_view.?.attach();
        _ = try self.services.set(views_service.views_service_id, &self.views_api);
        self.editor_groups_api = self.part.interface();
        _ = try self.services.set(editor_groups.editor_groups_service_id, &self.editor_groups_api);
        _ = try self.services.set(code_editor_service.code_editor_service_id, &self.code_editor_api);
        self.editors = .{ .part = self.part, .opening = &self.editor_opening };
        self.code_editors.opening = .{ .context = &self.editor_opening, .open = editor_service_mod.EditorOpening.requestOpenCodeEditor };
        self.editor_api = self.editors.interface();
        self.language_status_api = self.language_status.interface();
        _ = try self.services.set(@import("../vs/workbench/services/languageStatus/common/languageStatusService.zig").language_status_service_id, &self.language_status_api);
        self.language_status_contribution = try @import("../vs/workbench/contrib/languageStatus/browser/languageStatus.zig").LanguageStatusContribution.create(self.allocator, self.language_status_api, &self.statusbar, self.editors);
        errdefer {
            self.language_status_contribution.?.deinit();
            self.language_status_contribution = null;
        }
        _ = try self.services.set(@import("../vs/workbench/services/editor/common/editorService.zig").editor_service_id, &self.editor_api);
        const scm_view = try self.scm.ensureViewService(self.editor_api);
        _ = try self.services.set(@import("../vs/workbench/contrib/scm/common/scm.zig").scm_view_service_id, scm_view);
        _ = try scm_view.on_did_change_active_repository.listen(self, onActiveScmRepositoryChanged);
        _ = try self.services.set(@import("../vs/platform/files/common/files.zig").file_service_id, &self.file_service_api);
        _ = try self.services.set(@import("../vs/workbench/services/workingCopy/common/workingCopyFileService.zig").working_copy_file_service_id, &self.working_copy_file_api);
        _ = try self.services.set(@import("../vs/editor/common/services/resolverService.zig").text_model_service_id, &self.text_model_api);
        _ = try self.services.set(@import("../vs/editor/browser/services/bulkEditService.zig").bulk_edit_service_id, &self.bulk_edit_api);
        _ = try self.services.set(@import("../vs/editor/common/services/modelService.zig").model_service_id, &self.model_service_api);
        _ = try self.services.set(@import("../vs/workbench/contrib/scm/common/quickDiff.zig").quick_diff_service_id, self.scm.quick_diff_api.?);
        _ = try self.services.set(@import("../vs/workbench/contrib/scm/browser/quickDiffModel.zig").quick_diff_model_service_id, self.scm.quick_diff_model_api.?);
        _ = try self.services.set(@import("../vs/workbench/contrib/multiDiffEditor/browser/multiDiffSourceResolverService.zig").multi_diff_source_resolver_service_id, &self.multi_diff_sources_api);
        self.diff_commands = .{
            .editor_service = &self.editors,
            .snapshot_provider = .{ .context = &self.git_commands, .refresh = @import("../extensions/git/src/commands.zig").CommandContribution.refreshSnapshot },
        };
        self.diff_commands_api = self.diff_commands.interface();
        _ = try self.services.set(@import("../vs/workbench/browser/parts/editor/diffEditorCommandsService.zig").diff_editor_commands_service_id, &self.diff_commands_api);
        self.preferences = .{ .allocator = self.allocator, .editor_service = &self.editor_api, .text_file_service = &self.text_file_service, .settings_paths = &self.user_settings_paths, .keybindings_paths = &self.user_keybindings.paths };
        self.preferences_api = self.preferences.interface();
        _ = try self.services.set(@import("../vs/workbench/services/preferences/common/preferences.zig").preferences_service_id, &self.preferences_api);
        self.dialog_api = self.dialog_service.interface();
        _ = try self.services.set(dialogs.dialog_service_id, &self.dialog_api);
        self.environment_api = .{};
        _ = try self.services.set(@import("../vs/workbench/services/environment/common/environmentService.zig").workbench_environment_service_id, &self.environment_api);
        self.configuration_api = self.configuration_binding.interface();
        self.text_model_resolver.undo_store.?.configuration_service = self.configuration_api;
        self.bulk_edit_service.file_services.?.configuration_service = self.configuration_api;
        _ = try self.services.set(@import("../vs/platform/configuration/common/configuration.zig").configuration_service_id, &self.configuration_api);
        try self.accessible_view.bindServices(self.configuration_api, self.editor_api, self.clipboard_api);
        _ = try self.services.set(@import("../vs/platform/accessibility/browser/accessibleView.zig").accessible_view_service_id, &self.accessible_view_api);
        self.host_api = self.host_service.interface();
        self.storage_api = self.notification_storage.interface();
        _ = try self.services.set(@import("../vs/workbench/services/host/browser/host.zig").host_service_id, &self.host_api);
        _ = try self.services.set(storage_mod.storage_service_id, &self.storage_api);
        self.bulk_edit_preview_contribution = .{ .allocator = self.allocator, .views_service = self.views_api, .panes = self.pane_composite_api, .layout = self.layout_api, .editors = self.editor_api, .dialogs = self.dialog_api };
        self.bulk_edit_preview = BulkEditPane.init(self.allocator, .{ .files = self.file_service_api, .models = self.model_service_api, .text = self.text_model_api, .editors = self.editor_api, .window = &self.window_events, .dialogs = self.dialog_api, .storage = self.storage_api, .menus = &self.menu_service, .context_menu = self.context_menu_api }, .{ .context = self, .changed = requestWorkbenchFrame, .finished = struct {
            fn finish(context: *anyopaque) void {
                const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                if (host.bulk_edit_preview_contribution) |*contribution| contribution.onPaneFinished();
            }
        }.finish });
        try self.bulk_edit_preview_contribution.?.register(self.bulk_edit_api);
        self.terminal_action_services = @import("workbenchServices.zig").terminalActionServices(self);
        self.github_publish = .{
            .allocator = self.allocator,
            .io = self.io,
            .repository = &self.git_model.repository,
            .workspace = &self.workspace,
            .terminal = &self.terminal_action_services,
            .status_context = self,
            .report_status = scmViewStatus,
        };
        _ = try self.services.set(terminal_actions.terminal_action_services_id, &self.terminal_action_services);
        _ = try self.services.set(lifecycle_mod.lifecycle_service_id, &self.lifecycle_api);
        _ = try self.services.set(@import("../vs/platform/notification/common/notification.zig").notification_service_id, &self.notification_api);
    }

    fn restoreEditors(self: *TerminalWorkbench) !void {
        const states: []const editor_groups.SerializedEditorViewState = if (self.previous_state) |previous| if (previous.data) |data| blk: {
            try self.service.restoreSerializedEditors(data, previous.registry);
            break :blk data.editor_view_states;
        } else &.{} else &.{};
        self.previous_state = null;
        const panes = @import("../vs/workbench/browser/parts/editor/editorPane.zig").RestoredEditorPanes{
            .view_factory = self.view_factory,
            .io = self.io,
            .width = self.cols,
            .height = @max(self.rows -| 2, 1),
            .images = &self.images,
            .history = &self.history,
            .working_copies = &self.working_copy_service,
            .diff_options = @import("../vs/workbench/browser/parts/editor/textDiffEditor.zig").computeConfiguration(self.configuration_api),
            .editor_view_states = states,
            .share_view_state = self.configuration_api.getBool("workbench.editor.sharedViewState", false),
            .create_multi_diff = .{ .context = &self.editor_opening, .run = struct {
                fn create(context: *anyopaque, input: *@import("../vs/workbench/contrib/multiDiffEditor/browser/multiDiffEditorInput.zig").MultiDiffEditorInput, width: usize, height: usize) !*Tab {
                    const opening: *editor_service_mod.EditorOpening = @ptrCast(@alignCast(context));
                    return opening.createMultiDiffTab(input, width, height, true);
                }
            }.create },
            .on_restore = .{ .context = &self.editor_opening, .run = struct {
                fn configure(context: *anyopaque, tab: *Tab) !void {
                    const opening: *editor_service_mod.EditorOpening = @ptrCast(@alignCast(context));
                    try opening.configureRestoredTab(tab);
                }
            }.configure },
        };
        try self.part.restoreEditors(panes);
    }

    pub fn createFileSerializer(self: *TerminalWorkbench) FileEditorSerializer {
        var serializer = FileEditorSerializer.init(self.allocator, self.io, self.cols, self.editorContentHeight());
        serializer.undo_store = self.text_model_resolver.undo_store;
        return serializer;
    }

    fn initShellModels(self: *TerminalWorkbench, parent: *ui.Node, options: IWorkbenchOptions, has_previous_state: bool) !void {
        self.lists = .init(self.allocator);
        errdefer self.lists.deinit();
        self.host_service = .init(self.allocator);
        errdefer self.host_service.deinit();
        self.dialog_service = .init(self.allocator);
        errdefer self.dialog_service.deinit();
        self.dialog_handler = try @import("../vs/workbench/browser/parts/dialogs/dialog.web.contribution.zig").DialogHandlerContribution.create(self.allocator, &self.dialog_service.model);
        errdefer self.dialog_handler.destroy();
        self.problems_view = null;
        self.bulk_edit_preview = null;
        self.bulk_edit_preview_contribution = null;
        self.marker_listener = null;
        self.markers_status = null;
        self.range_highlights = null;
        self.core = workbench_core.Workbench.init(self.allocator, parent, options, has_previous_state);
        self.layout = &self.core.layout;
        self.instantiation = &self.core.instantiation;
        self.layout.zen_host = .{
            .context = self,
            .get_configuration = readZenModeConfiguration,
            .get_centered_options = centeredEditorOptions,
            .configured_visible = configuredPartVisible,
            .get_focused_part = focusedLayoutPart,
            .focus_part = focusLayoutPart,
            .apply_line_numbers = applyZenLineNumbers,
        };
        errdefer self.core.deinit();
        self.activity_bar_part = ActivityBarPart.init(self.allocator);
        errdefer self.activity_bar_part.deinit();
        self.sidebar_part = SidebarPart.init(self.allocator);
        errdefer self.sidebar_part.deinit();
        self.sidebar_part.attachActivityBar(&self.activity_bar_part);
        self.panel_part = PanelPart.init(self.allocator);
        errdefer self.panel_part.deinit();
        self.sidebar_part.base.resize_primary = SidebarPart.resizeWidth;
        const layout_service = self.layout.interface();
        try self.sidebar_part.base.register(layout_service);
        try self.panel_part.base.register(layout_service);
        try self.activity_bar_part.base.register(layout_service);
        self.view_containers_registry = views_mod.ViewContainersRegistry.init(self.allocator);
        errdefer self.view_containers_registry.deinit();
        self.views_registry = .init(self.allocator);
        errdefer self.views_registry.deinit();
        self.view_descriptor_service = ViewDescriptorService.init(self.allocator, &self.view_containers_registry);
        errdefer self.view_descriptor_service.deinit();
        self.window_views = ViewsService.init(self.allocator, &self.view_descriptor_service, &self.sidebar_part);
        errdefer self.window_views.deinit();
        self.view_descriptor_service.views_registry = &self.views_registry;
        try self.view_descriptor_service.attach();
        _ = try self.view_descriptor_service.on_did_change_container.listen(self, onViewContainerChanged);
        self.notification_storage = storage_mod.InMemoryStorageService.init(self.allocator);
        errdefer self.notification_storage.deinit();
        if (options.profile_storage_path) |path| self.notification_storage.attachProfileStorage(self.io, path) catch |err| std.log.scoped(.storage).warn("Profile storage unavailable: {s}", .{@errorName(err)});
        self.notification_service = try @import("../vs/workbench/services/notification/common/notificationService.zig").NotificationService.create(self.allocator, &self.notification_storage);
        errdefer self.notification_service.deinit();
        self.notification_api = self.notification_service.interface();
        self.layout.notification_service = self.notification_api;
        self.statusbar = try StatusbarService.init(self.allocator);
        errdefer self.statusbar.deinit();
        self.language_status = .init(self.allocator);
        errdefer self.language_status.deinit();
        self.language_status_contribution = null;
        try self.statusbar.main_part.base.register(layout_service);
        self.activity_service = ActivityService.init(self.allocator);
        errdefer self.activity_service.deinit();
        const scm_api = try self.scm.ensureService();
        errdefer self.scm.deinit();
        _ = try self.scm.ensureQuickDiffServices(&self.window_events, self.text_model_api, &self.notification_storage);
        const sources = @import("../vs/workbench/contrib/multiDiffEditor/browser/multiDiffSourceResolverService.zig");
        self.multi_diff_sources = sources.MultiDiffSourceResolverService.init(self.allocator);
        errdefer self.multi_diff_sources.deinit();
        self.multi_diff_sources_api = self.multi_diff_sources.interface();
        self.scm_multi_diff_resolvers = try @import("../vs/workbench/contrib/multiDiffEditor/browser/scmMultiDiffSourceResolver.zig").ScmMultiDiffSourceResolverContribution.create(self.allocator, scm_api.*, &self.activity_service, self.multi_diff_sources_api);
        errdefer self.scm_multi_diff_resolvers.dispose();

        try self.layout.setSize(.sidebar, 28);

        for (activity_bar_mod.default_activities) |activity| {
            try self.activity_bar_part.addActivity(activity);
        }
        try self.activity_bar_part.setVisible(true);

        try @import("../vs/workbench/workbench.common.main.zig").registerViewContainers(&self.view_containers_registry);
        try @import("../vs/workbench/workbench.common.main.zig").registerViews(&self.views_registry);
        try @import("../vs/workbench/browser/parts/paneCompositePartService.zig").PaneCompositePartService.populateParts(&self.sidebar_part, &self.panel_part, &self.view_descriptor_service);
        try self.initExplorerContainer();
        try self.sidebar_part.setWidth(28);
        try self.initStatusHint();
    }

    /// Port of the Explorer viewlet's two stacked views. Upstream registers
    /// Explorer and Outline in the Explorer view container; the terminal
    /// `ViewPaneContainer` renders their section headers and splits the body.
    fn initExplorerContainer(self: *TerminalWorkbench) !void {
        const model = try self.allocator.create(view_container_model_mod.ViewContainerModel);
        errdefer self.allocator.destroy(model);
        model.* = view_container_model_mod.ViewContainerModel.init(self.allocator, .{
            .id = "explorer",
            .title = "Explorer",
            .icon = "E",
        });
        errdefer model.deinit();

        const panes = try self.allocator.alloc(view_pane_container_mod.Pane, 4);
        errdefer self.allocator.free(panes);
        panes[0] = .{
            .id = "explorer",
            .title = "Explorer",
            .context = self,
            .render_body = explorerPaneRenderBody,
            .handle_key = explorerPaneHandleKey,
            .set_focused = struct {
                fn run(context: *anyopaque, focused: bool) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    if (host.sidebar) |pane| pane.setPaneFocused(focused);
                }
            }.run,
            .handle_mouse = explorerPaneHandleMouse,
            .title_actions = explorerPaneTitleActions,
            .set_body_visible = explorerPaneBodyVisible,
        };
        panes[1] = .{
            .id = "outline",
            .title = "Outline",
            .context = self,
            .render_body = outlinePaneRenderBody,
            .handle_key = outlinePaneHandleKey,
            .set_focused = struct {
                fn run(context: *anyopaque, focused: bool) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    if (host.outline_view) |pane| pane.setPaneFocused(focused);
                }
            }.run,
            .handle_mouse = outlinePaneHandleMouse,
            .title_actions = outlinePaneTitleActions,
            .overflow_action_id = OutlinePane.more_actions_id,
            .set_visible = outlinePaneViewVisible,
            .set_body_visible = outlinePaneBodyVisible,
            .append_secondary_actions = struct {
                fn run(context: *anyopaque, menu: *Menu, service: *@import("../vs/platform/actions/common/menuService.zig").MenuService, keys: @import("../vs/platform/contextkey/common/contextkey.zig").IContext) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    if (host.outline_view) |view| try @import("../vs/workbench/contrib/outline/browser/outlineActions.zig").appendSecondary(menu, service, keys, &view.view_state);
                }
            }.run,
        };
        panes[2] = .{
            .id = "changes",
            .title = "Changes",
            .context = self,
            .render_body = scmChangesRenderBody,
            .handle_key = scmChangesHandleKey,
            .set_focused = struct {
                fn run(context: *anyopaque, focused: bool) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    if (host.scm.changes) |pane| pane.setPaneFocused(focused);
                }
            }.run,
            .handle_mouse = scmChangesHandleMouse,
            .title_actions = scmChangesTitleActions,
            .overflow_action_id = scm_view_mod.CHANGES_MENU_ACTION_ID,
            .append_secondary_actions = struct {
                fn run(context: *anyopaque, menu: *Menu, service: *@import("../vs/platform/actions/common/menuService.zig").MenuService, keys: @import("../vs/platform/contextkey/common/contextkey.zig").IContext) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    if (host.scm.changes) |view| try scm_view_mod.appendSecondary(menu, service, keys, view);
                }
            }.run,
        };
        panes[3] = .{
            .id = "graph",
            .title = "Graph",
            .context = self,
            .render_body = scmHistoryRenderBody,
            .handle_key = scmHistoryHandleKey,
            .set_focused = struct {
                fn run(context: *anyopaque, focused: bool) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    if (host.scm.history) |pane| pane.setPaneFocused(focused);
                }
            }.run,
            .handle_mouse = scmHistoryHandleMouse,
            .title_actions = scmHistoryTitleActions,
            .overflow_action_id = scm_history_view_mod.GRAPH_MENU_ACTION_ID,
            .append_secondary_actions = struct {
                fn run(context: *anyopaque, menu: *Menu, service: *@import("../vs/platform/actions/common/menuService.zig").MenuService, keys: @import("../vs/platform/contextkey/common/contextkey.zig").IContext) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    if (host.scm.history) |view| try scm_history_view_mod.appendSecondary(menu, service, keys, view);
                }
            }.run,
            .show_actions = .when_expanded,
        };
        for (panes) |*pane| pane.run_title_action = runPaneTitleAction;
        const container = try self.sidebar_part.createViewPaneContainer(&self.view_descriptor_service, model, panes);
        self.explorer_panes = panes;
        self.explorer_view_model = model;
        self.explorer_container = container;
    }

    fn initStatusHint(self: *TerminalWorkbench) !void {
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

    fn deinitBulkEditPreview(self: *TerminalWorkbench) void {
        if (self.bulk_edit_preview) |*pane| pane.deinit();
        self.bulk_edit_preview = null;
        if (self.bulk_edit_preview_contribution) |*contribution| contribution.deinit();
        self.bulk_edit_preview_contribution = null;
    }

    fn deinitShellModels(self: *TerminalWorkbench) void {
        self.deinitBulkEditPreview();
        self.lists.deinit();
        self.core.disposeListeners();
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
            self.sidebar_part.disposeViewPaneContainer(&self.view_descriptor_service, container);
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
        extensions_view_host.detach(self);
        self.scm_multi_diff_resolvers.dispose();
        self.multi_diff_sources.deinit();
        self.scm.deinit();
        self.activity_service.deinit();
        self.core.disposeNotifications();
        self.host_service.deinit();
        if (self.output_view) |*view| view.deinit();
        self.output_view = null;
        self.language_status.deinit();
        self.statusbar.deinit();
        self.notification_service.deinit();
        self.notification_storage.deinit();
        self.panel_part.deinit();
        self.window_views.deinit();
        self.sidebar_part.deinit();
        self.view_descriptor_service.deinit();
        self.views_registry.deinit();
        self.view_containers_registry.deinit();
        self.activity_bar_part.deinit();
        self.core.deinit();
    }

    fn initQuickAccess(self: *TerminalWorkbench) !void {
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
                .editor_service = &self.editor_api,
                .preferences = &self.preferences_api,
                .code_editors = &self.code_editor_api,
                .lookup_keycaps = quickLookupKeycaps,
                .report_error = quickReportError,
                .cancel_popups = quickCancelPopups,
                .get_excludes = quickGetExcludes,
                .get_file_search_settings = quickGetFileSearchSettings,
            },
        );
        errdefer self.quick_access.deinit();
        self.quick_input_api = self.quick_access.interface();
        _ = try self.services.set(@import("../vs/platform/quickinput/common/quickInput.zig").quick_input_service_id, &self.quick_input_api);

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
        try self.editor_status.?.bindTabFocus(&self.tab_focus);
        self.media_status = try MediaPreviewStatus.init(self.allocator, &self.statusbar);
        errdefer {
            if (self.media_status) |status| status.deinit();
            self.media_status = null;
        }

        self.simple_browser = .{ .allocator = self.allocator, .io = self.io, .quick_input = self.quick_access.inputService(), .context = self, .open_editor = openTerminalEditorWithProfile, .report_error = reportEditorMessage };
        self.builtin_host = try @import("../vs/workbench/api/browser/builtinExtensionHost.zig").BuiltinExtensionHost.init(self.allocator, self.builtinExtensionServices());
        self.statusbar.setCommandExecutor(.{
            .context = self,
            .execute = executeStatusbarCommand,
        });
    }

    pub fn builtinExtensionServices(self: *TerminalWorkbench) @import("../vs/workbench/api/browser/builtinExtensionHost.zig").Services {
        return @import("workbenchServices.zig").builtinExtensionServices(self);
    }

    pub fn extensionHostServices(self: *TerminalWorkbench) @import("../vs/workbench/api/browser/extensionHostServices.zig").Services {
        return @import("workbenchServices.zig").extensionHostServices(self);
    }

    fn registerActions(self: *TerminalWorkbench) !void {
        const main = @import("../vs/workbench/workbench.common.main.zig");
        try main.registerActions(&self.commands, self.instantiation, .{
            .editor_status = self.editor_status.?,
            .groups = &self.group_actions,
            .breadcrumbs = &self.breadcrumbs,
            .search_editor = &self.search_window.factory,
            .github_publish = self.github_publish.descriptor(),
            .simple_browser = &self.simple_browser.actions(),
            .git_refresh = &self.git_commands.refreshActions(),
            .git_remote = &self.git_commands.remoteActions(),
            .git_open = &self.git_commands.openActions(),
            .git_diff = &(self.git_commands.diffActions() ++ self.git_commands.multiDiffActions()),
            .markdown = &self.markdown_previews.actionDescriptors(),
        });
        try self.builtin_host.registerPortActions();
        try self.references_view.init(&self.builtin_host.context, self.quick_access.inputService());
        self.references_view_registered = true;
        try main.registerEditorNavigationActions(&self.commands, self.instantiation, &self.symbol_navigation, &self.symbol_quick_access);
    }

    fn reportMenuError(context: *anyopaque, err: anyerror) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        if (self.activeTab()) |tab| tab.editor.setMessage("Menu action failed: {s}", .{@errorName(err)});
    }

    fn applyContextMenuTheme(self: *TerminalWorkbench, palette: ?*const theme_colors_mod.ThemeColors) void {
        var theme = ui.ContextMenuTheme{};
        if (palette) |colors| {
            theme.background = colors.colorOr("menu.background", theme.background);
            theme.foreground = colors.colorOr("menu.foreground", theme.foreground);
            theme.border = colors.colorOr("menu.border", theme.border);
            theme.separator = colors.colorOr("menu.separatorBackground", theme.separator);
            theme.selection_background = colors.colorOr("menu.selectionBackground", theme.selection_background);
            theme.selection_foreground = colors.colorOr("menu.selectionForeground", theme.selection_foreground);
            theme.disabled = colors.colorOr("disabledForeground", theme.disabled);
        }
        self.context_menu_service.theme = theme;
    }

    pub fn isDialogOpen(self: *const TerminalWorkbench) bool {
        return self.dialog_service.hasDialog();
    }

    /// True once the quit confirmation saved or discarded every dirty tab and
    /// the host should leave the event loop.
    pub fn shouldQuit(self: *const TerminalWorkbench) bool {
        return self.quit_requested;
    }

    pub fn isQuickAccessOpen(self: *const TerminalWorkbench) bool {
        return self.quick_access.isOpen();
    }

    pub fn findInFiles(self: *TerminalWorkbench) !void {
        const search = @import("../vs/workbench/contrib/search/browser/searchActionsBase.zig");
        if (try search.openSearchView(self.views_api, true)) |view| try search.findInFiles(view);
    }

    pub fn replaceInFiles(self: *TerminalWorkbench) !void {
        const search = @import("../vs/workbench/contrib/search/browser/searchActionsBase.zig");
        if (try search.openSearchView(self.views_api, true)) |view| search.replaceInFiles(view);
    }

    /// Enables the threaded TextMate background tokenizer. The TUI calls
    /// this after construction; tests leave it off so they keep the
    /// synchronous default background tokenizer.
    pub fn enableAsyncTokenization(self: *TerminalWorkbench) void {
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

    pub fn deinit(self: *TerminalWorkbench) void {
        if (self.language_status_contribution) |contribution| contribution.deinit();
        self.language_status_contribution = null;
        if (self.json_client) |client| client.attachWindow(null);
        self.text_model_resolver.cancelPendingSaves();
        self.deinitBulkEditPreview();
        self.editor_opening.unbindWorkingCopyFileService();
        self.text_file_model_manager.deinit();
        self.accessible_view.deinit();
        self.sidebar_part.setFocused(false);
        for (self.focus_subscriptions) |subscription| if (subscription) |value| value.dispose();
        if (self.terminal_focus_subscription) |subscription| subscription.dispose();
        self.terminal_tabbed_view.on_list_focus = null;
        self.core.cancelRestoreTimer();
        // Title menus subscribe to the shared registry and scoped contexts.
        // Detach them before those services are disposed, not with the later
        // native tab/view teardown.
        self.part.disposeTitleMenus();
        // The diff breadcrumb contribution borrows the shared outline service.
        for (self.part.group_views.items) |pane| for (pane.tabs.items) |tab| {
            tab.detachMultiDiffControls();
            tab.detachDiffBreadcrumbs();
            tab.detachCodeLensServices();
            if (tab.diff) |diff| diff.widget.detachContributions();
        };
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
        self.breadcrumbs.deinit();
        self.symbol_navigation.deinit();
        self.symbol_quick_access.deinit();
        if (self.outline_creator) |*creator| creator.dispose();
        self.action_widget_service.deinit();
        self.context_menu_service.deinit();
        self.clipboard_service.deinit();
        if (self.home_path) |home| {
            self.allocator.free(home);
            self.home_path = null;
        }
        if (self.references_view_registered) self.references_view.deinit();
        self.builtin_host.deinit();
        if (self.outline_view) |view| {
            view.deinit();
            self.outline_view = null;
        }
        self.outline_service.deinit();
        self.core.disposeInstantiation();
        self.services.deinit();
        if (self.media_status) |status| {
            status.deinit();
            self.media_status = null;
        }
        if (self.editor_status) |status| {
            status.deinit();
            self.editor_status = null;
        }
        self.git_commands.deinit();
        self.deinitGit();
        self.git_file_provider.deinit();
        self.search_window.destroy();
        if (self.sidebar) |sidebar| sidebar.deinit();
        self.sidebar = null;
        self.deinitShellModels();
        if (self.tab_service) |service| service.deinit();
        if (self.global_service) |service| {
            service.deinit();
        }
        self.user_keybindings.destroy();
        if (self.context_keys) |service| {
            self.configuration_context.deinit();
            service.deinit();
            self.allocator.destroy(service);
        }
        if (self.theme_palette) |palette| self.allocator.destroy(palette);
        if (self.syntax_theme_ready) self.syntax_theme.deinit();
        if (self.theme_service) |service| service.deinit();
        self.quick_access.deinit();
        self.text_model_resolver.bindWorkingCopyService(null) catch {};
        self.working_copy_service.deinit();
        self.menu_service.deinit();
        self.commands.deinit();
        self.history.deinit();
        // Dispose the service (and unregister editor listeners) before tab
        // inputs/emitters are destroyed.
        self.editor_configuration.deinit();
        self.configured_languages.deinit();
        self.part.disposeGroupModelListeners();
        self.markdown_previews.deinit();
        self.service.deinit();
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
        self.lifecycle.deinit();
        self.configuration_migrations.deinit();
        if (self.text_model_resolver.undo_store) |store| store.configuration_service = null;
        self.configuration_binding.deinit();
        if (self.configuration) |configuration| configuration.deinit();
        freeOwnedPaths(self.allocator, self.user_settings_paths);
        self.workspace.deinit();
        // The part owns the group views; disposing it disposes the tab views.
        self.part.deinit();
        self.tab_focus.deinit();
        self.text_model_resolver.deinit();
        self.word_highlight_session.deinit();
        self.code_editors.deinit();
        self.working_copy_file_service.deinit();
        self.output_service.deinit();
        self.extension_logger_service.deinit();
        self.disk_resource_registration.dispose();
        self.disk_resource_provider.deinit();
        self.resource_file_service.deinit();
        self.window_events.deinitWindowEvents();
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
        if (self.textual_highlight_feature) |feature| feature.dispose();
        if (self.word_completion_provider) |provider| self.allocator.destroy(provider);
        if (self.marker_decorations) |service| service.deinit();
        if (self.marker_navigation) |*service| service.deinit();
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
        self.editor_opening.deinit();
        self.text_file_service.deinit();
        self.disk_files.deinit();
        self.async_io_state.deinit();
        self.worker_io_state.deinit();
        self.allocator.destroy(self);
    }

    /// The terminal supplies only its cell dimensions and a view of the
    /// registered parts. Layout owns the grid and size constraints.
    pub fn geometry(self: *const TerminalWorkbench) workbench_layout.TerminalGeometry {
        return .{ .layout = self.layout, .cols = self.cols, .rows = self.rows, .part = self.part, .sidebar_part = &self.sidebar_part, .activity_bar_part = &self.activity_bar_part, .panel_part = &self.panel_part, .sidebar_available = self.sidebar != null };
    }

    /// The Terminal container is active and has at least one instance.
    pub fn terminalVisible(self: *const TerminalWorkbench) bool {
        if (!self.geometry().panelShown()) return false;
        if (!std.mem.eql(u8, self.geometry().activePanelId(), TERMINAL_CONTAINER_ID)) return false;
        return self.terminal_service != null and self.terminal_service.?.count() > 0;
    }

    /// Editor content height: the rows above the workbench status bar minus the
    /// group chrome (tab strip plus the optional breadcrumb row).
    fn editorContentHeight(self: *TerminalWorkbench) usize {
        return @max(self.geometry().editorRows() -| self.chromeHeight(), 1);
    }

    fn chromeHeight(self: *TerminalWorkbench) usize {
        const tabs: usize = if (self.part.part_options.show_tabs == .none) 0 else editor_group_view.title_height;
        return tabs + (if (self.breadcrumbs.settings.enabled) editor_group_view.breadcrumbs_height else 0);
    }

    pub fn setSidebarVisible(self: *TerminalWorkbench, visible: bool) !void {
        try self.layout.setPartHidden(!visible, .sidebar);
        if (visible) try self.syncActivityBarVisibility();
    }

    fn onGridChanged(_: void, self: *TerminalWorkbench) !void {
        self.layoutAll();
        self.updatePartFocus() catch {};
        self.requestFrame();
    }

    fn sidebarMenuAnchor(self: *TerminalWorkbench, id: []const u8) MenuAnchor {
        if (self.sidebar_action_anchor) |anchor| return anchor;
        if (self.activeSidebarViewContainer()) |container| {
            if (container.titleActionRect(id)) |rect| return .{ .x = ui.cell.snap(rect.x), .y = ui.cell.snap(rect.bottom()) };
        }
        const rect = self.geometry().sidebarRect();
        return .{ .x = ui.cell.snap(rect.right()) -| 1, .y = ui.cell.snap(rect.y) + 1 };
    }

    pub fn runSidebarTitleAction(self: *TerminalWorkbench, id: []const u8, event: ?*const ui.MouseEvent) void {
        const previous = self.sidebar_action_anchor;
        defer self.sidebar_action_anchor = previous;
        self.sidebar_action_anchor = if (event) |e| MenuAnchor.mouse(e) else null;
        self.commands.execute(id) catch {};
    }

    pub fn activeActivity(self: *const TerminalWorkbench) usize {
        return self.activity_bar_part.activeIndex() orelse 0;
    }

    /// Shows the activity container with `id` (for example `workbench.view.scm`).
    pub fn showActivityById(self: *TerminalWorkbench, id: []const u8) !bool {
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
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
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
    pub fn setWorkspaceFolders(self: *TerminalWorkbench, folders: []const []const u8) !void {
        const replacement = try WorkspaceContextService.initWithFolders(self.allocator, "workspace", folders);
        defer replacement.deinit();
        self.sidebar_part.setFocused(false);
        if (self.sidebar) |sidebar| {
            sidebar.deinit();
            self.sidebar = null;
        }
        self.search_window.destroy();
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
            self.markdown_previews.detachConfiguration();
            if (self.search_window.view) |view| view.detachConfiguration();
            self.git_model.detachConfiguration();
            self.scm.detachConfiguration();
            if (self.theme_service) |service| service.detachConfiguration();
            if (self.core.notification_controller) |controller| try controller.attachConfiguration(null);
            try self.configuration_migrations.bind(null);
            try self.configuration_binding.bind(null);
            configuration.deinit();
            self.configuration = null;
        }
        // Stop the quick-open listing while the old workspace snapshot is
        // still alive; the worker owns copies, but this keeps the ordering
        // explicit and drops picker items that borrow old paths.
        self.quick_access.endFileSession();
        if (self.terminal_service) |service| service.options.workspace_root = null;
        self.saveSidebarViewStates() catch {};
        // The context service (and its subscribers) has window lifetime.
        // Keep the previous model alive in replacement until the event has
        // delivered both added and removed folder descriptors.
        self.workspace.swapWorkspace(replacement);
        self.editor_opening.setMultiDiffWorkspace(self.workspace);
        self.search_window.setWorkspace(self.workspace);
        if (self.view_state_storage != null) {
            try self.view_descriptor_service.resetRegisteredModels();
            try self.restoreSidebarViewStates();
        }
        try self.ensureConfiguration();
        if (self.terminal_service) |service| {
            service.options.workspace_root = self.workspaceFolderPath();
            service.options.multi_root = self.workspace.getWorkspace().folders.items.len > 1;
        }
        self.layoutAll();
        try self.quick_access.setWorkspace(self.workspace);
        try self.workspace.notifyWorkspaceFoldersChanged(replacement.getWorkspace());
        if (self.lifecycle.phase.reached(.Restored) and self.workspace.getWorkspace().folders.items.len > 0) {
            self.ensureWorkspaceWatcher() catch |err| {
                std.log.scoped(.file_watcher).err("failed to start workspace watcher: {s}", .{@errorName(err)});
            };
        }
    }

    /// Sets the user settings files before the Explorer/configuration service
    /// is created. The app derives them from the VS Code profile and the
    /// terminal's own config directory; later layers override earlier ones.
    pub fn setUserConfigurationValue(self: *TerminalWorkbench, key: []const u8, value: ?std.json.Value) !void {
        try self.ensureConfiguration();
        try self.configuration_api.updateValue(key, value, .USER);
    }

    pub fn setUserSettingsPaths(self: *TerminalWorkbench, paths: []const []const u8) !void {
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
            self.markdown_previews.detachConfiguration();
            if (self.search_window.view) |view| view.detachConfiguration();
            self.git_model.detachConfiguration();
            self.scm.detachConfiguration();
            if (self.theme_service) |service| service.detachConfiguration();
            if (self.core.notification_controller) |controller| try controller.attachConfiguration(null);
            try self.configuration_migrations.bind(null);
            try self.configuration_binding.bind(null);
            configuration.deinit();
            self.configuration = null;
            try self.ensureConfiguration();
            self.configureJsonLanguage();
            try self.layout.onZenModeConfigurationChange(null);
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
    pub fn setKeybindingsPaths(self: *TerminalWorkbench, paths: []const []const u8) !void {
        try self.user_keybindings.setPaths(paths, self.ensureFileService() catch null);
    }

    fn ensureConfiguration(self: *TerminalWorkbench) !void {
        if (self.configuration != null) return;
        self.configuration = try ConfigurationService.init(
            self.allocator,
            self.io,
            self.workspace,
            .{
                .user_settings_paths = self.user_settings_paths,
                .register_configuration = @import("../vs/workbench/workbench.common.main.zig").registerConfigurations,
                .defaults_json = &.{
                    search_configuration.defaults_json,
                    terminal_configuration.defaults_json,
                    theme_configuration_mod.defaults_json,
                    workbench_configuration.defaults_json,
                    zen_mode_contribution.defaults_json,
                    @import("../vs/workbench/contrib/accessibility/browser/accessibilityConfiguration.zig").defaults_json,
                },
            },
        );
        try self.configuration_binding.bind(self.configuration);
        const themes = try self.ensureThemeService();
        try themes.setConfiguration(self.configuration.?);
        try self.git_model.setConfiguration(self.configuration);
        try self.scm.setConfiguration(self.configuration);
        try self.markdown_previews.attachConfiguration(self.configuration.?);
        if (self.search_window.view) |view| try view.attachConfiguration(self.configuration.?);
        if (self.core.notification_controller) |controller| try controller.attachConfiguration(self.configuration);
        try self.configuration.?.onDidChangeConfiguration(self, onWorkbenchConfigurationChange);
        try self.tab_focus.setTabFocusMode(self.configuration.?.getBool("editor.tabFocusMode", false));
        if (self.declarative) |catalog| try self.applyExtensionDefaults(catalog);
        if (self.terminal_service) |service| service.options.configuration = self.configuration;
        self.settings_watcher = SettingsWatcher.init(self.allocator, self.io, self.configuration.?, try self.ensureFileService(), &self.window_events) catch null;
        if (self.settings_watcher) |watcher| {
            watcher.setAsyncIo(self.async_io);
        }
        try self.breadcrumbs.attachServices(self.workspace, self.configuration);
        try self.configuration_migrations.bind(self.configuration);
        self.applyLayoutSettings(null);
    }

    fn onTabFocusChanged(_: bool, self: *TerminalWorkbench) !void {
        self.updateContextKeys();
        self.requestFrame();
    }

    fn onWorkbenchConfigurationChange(change: configuration_mod.Change, self: *TerminalWorkbench) !void {
        const config = @import("../vs/platform/configuration/common/configuration.zig");
        if (config.affectsConfiguration(change, "editor.tabFocusMode")) {
            try self.tab_focus.setTabFocusMode(self.configuration.?.getBool("editor.tabFocusMode", false));
        }
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
    }

    pub fn handleFileChanges(self: *TerminalWorkbench, changes: []const @import("../vs/platform/files/common/files.zig").FileChange) void {
        self.editor_opening.handleFileChanges(changes);
    }

    pub fn workingCopyService(self: *TerminalWorkbench) *WorkingCopyService {
        return &self.working_copy_service;
    }

    fn acquireWorkingEditor(self: *TerminalWorkbench, editor: *Editor) void {
        editor.undo_redo.setNotificationService(self.notification_api);
        if (!self.working_copy_service.hasResource(editor.path)) {
            if (self.search_window.view) |view| view.model.result.onModelAdded(editor.path, editor.model) catch {};
        }
        self.working_copy_service.acquireWorkingCopy(tui_editor_mod.workingCopyInterface(editor)) catch {};
    }

    fn releaseWorkingEditor(self: *TerminalWorkbench, editor: *Editor) void {
        _ = self.working_copy_service.releaseWorkingCopy(tui_editor_mod.workingCopyInterface(editor));
    }

    fn registerWorkingCopy(self: *TerminalWorkbench, tab: *Tab) void {
        for (0..tab.workingCopyCount()) |index| {
            const editor = tab.workingCopyAt(index) orelse continue;
            self.acquireWorkingEditor(editor);
        }
    }

    fn unregisterWorkingCopy(self: *TerminalWorkbench, tab: *Tab) void {
        for (0..tab.workingCopyCount()) |index| {
            const editor = tab.workingCopyAt(index) orelse continue;
            self.releaseWorkingEditor(editor);
        }
    }

    fn initAfterRestoredWorkspaceWatcher(context: *anyopaque) !void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        try self.ensureWorkspaceWatcher();
    }

    pub fn ensureFileService(self: *TerminalWorkbench) !*FileWatcherService {
        if (self.file_watcher_service == null) {
            const service = try FileWatcherService.init(self.allocator, self.io);
            errdefer service.deinit();
            _ = try service.on_did_change.listen(self, onWorkspaceFileChanges);
            service.client.attachWindow(&self.window_events);
            self.file_watcher_service = service;
        }

        return self.file_watcher_service.?;
    }

    fn ensureWorkspaceWatcher(self: *TerminalWorkbench) !void {
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
        for (self.git_model.repositories()) |provider| provider.watch(self.file_watcher_service.?) catch {};
    }

    fn onWorkspaceFileChanges(changes: []const @import("../vs/platform/files/common/files.zig").FileChange, self: *TerminalWorkbench) !void {
        self.handleFileChanges(changes);
    }

    fn reportWatcherMessage(_: *anyopaque, message: []const u8) void {
        std.log.scoped(.file_watcher).warn("{s}", .{message});
    }

    /// Test/standalone helper: set a single-folder workspace and open the
    /// Explorer on it.
    pub fn initSidebar(self: *TerminalWorkbench, root_path: []const u8) !void {
        try self.setWorkspaceFolders(&.{root_path});
        try self.initSidebarFromWorkspace();
    }

    pub fn initSidebarFromWorkspace(self: *TerminalWorkbench) !void {
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
            try self.sidebar.?.registerList(&self.lists, &self.editor_api);
            try self.sidebar.?.attachEditorService(&self.editor_api, self.configuration_api);
            self.sidebar.?.setThemeColors(self.theme_palette);
        }
        if (self.search_window.view == null) try self.search_window.initFromWorkspace();
        self.sidebar.?.theme_service = self.theme_service;
        self.sidebar.?.setOpenEditorQuery(.{ .context = self, .is_open = isPathOpen });
        _ = try self.activity_bar_part.setActive(self.activity_bar_part.activities.items[0].id);
        _ = try self.sidebar_part.openPaneComposite(self.activity_bar_part.activities.items[0].id);
        try extensions_view_host.attach(self);
        try self.setSidebarVisible(true);
        self.sidebar_part.setFocused(self.focus == .sidebar);
        self.layoutAll();
    }

    pub fn showActivity(self: *TerminalWorkbench, index: usize) !void {
        const activity = self.activity_bar_part.activityAtVisibleIndex(index) orelse return;
        try self.openActivity(activity.id, true);
    }

    fn openActivity(self: *TerminalWorkbench, id: []const u8, focus: bool) !void {
        if (self.sidebar == null or self.search_window.view == null) try self.initSidebarFromWorkspace();
        // Switching the visible view container invalidates the hover state
        // painted by the previous one.
        self.clearSidebarViewHover();
        if (self.activeSidebarViewContainer()) |container| container.cancelHeaderDrag();
        _ = try self.activity_bar_part.setActive(id);
        if (!std.mem.eql(u8, id, "search")) if (self.search_window.view) |view| view.blur();
        _ = try self.sidebar_part.openPaneComposite(id);
        try self.setSidebarVisible(true);
        try self.syncActivityBarVisibility();
        if (focus) {
            self.setFocus(.sidebar);
            self.statusbar.main_part.clearFocus();
            if (std.mem.eql(u8, id, "search")) {
                if (self.search_window.view) |view| view.focus();
            }
        }
        if (self.range_highlights) |highlights| highlights.removeHighlightRange();
        self.layoutAll();
    }

    pub fn toggleSidebar(self: *TerminalWorkbench) !void {
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

    /// Browser Tab navigation crosses workbench DOM parts. Native parts
    /// have independent focus surfaces, so move between their registered
    /// layout containers only when the focused control has no next stop.
    pub fn handleTabFocus(self: *TerminalWorkbench, event: *ui.KeyEvent) bool {
        if (event.mods.ctrl or event.mods.alt or self.isDialogOpen() or self.quick_access.isOpen() or self.accessible_view.visible()) return false;
        const target = self.code_editor_api.getFocusedCodeEditor() orelse self.code_editor_api.getActiveCodeEditor();
        const configured = self.focus == .editor and if (target) |editor| editor.getTabFocusMode() else false;
        if (!self.tab_focus.getTabFocusMode() and !configured) return false;
        if (event.key != .tab and event.key != .backtab) return false;
        const direction: ui.dom.FocusDirection = if (event.key == .backtab or event.mods.shift) .backward else .forward;
        const layout_api = self.layout.interface();
        const part: layout_service_mod.Parts = switch (self.focus) {
            .editor => .editor,
            .sidebar => .sidebar,
            .terminal, .problems, .bulk_edit, .output => .panel,
            .statusbar => .statusbar,
            .breadcrumbs => return false,
        };
        if (part == .editor) if (self.activeTab()) |tab| {
            if (tab.dispatchTabFocus(event, direction)) {
                self.requestFrame();
                return true;
            }
        };
        const parts = [_]layout_service_mod.Parts{ .sidebar, .editor, .panel, .statusbar };
        const current = for (parts, 0..) |candidate, index| {
            if (candidate == part) break index;
        } else return false;
        for (1..parts.len) |offset| {
            const index = if (direction == .forward) (current + offset) % parts.len else (current + parts.len - offset) % parts.len;
            const next = parts[index];
            if (!layout_api.isVisible(next)) continue;
            layout_api.focusPart(next);
            if (next == .editor) if (self.activeTab()) |tab| tab.focusTabEdge(direction);
            self.requestFrame();
            return true;
        }
        return true;
    }

    pub fn focusSidebar(self: *TerminalWorkbench) void {
        if (!self.geometry().sidebarShown()) return;
        self.setFocus(.sidebar);
        self.updateProblemsHighlight();
        if (self.breadcrumbs.activeControl()) |control| control.setFocused(false);
        self.statusbar.main_part.clearFocus();
        if (std.mem.eql(u8, self.activity_bar_part.active_id orelse "", "search")) {
            if (self.search_window.view) |view| view.focus();
        }
    }

    pub fn focusEditor(self: *TerminalWorkbench) void {
        if (!self.layout.isVisible(.editor)) self.layout.setPartHidden(false, .editor) catch {};
        self.setFocus(.editor);
        if (self.activeSidebarViewContainer()) |container| {
            container.cancelHeaderDrag();
            container.focused_header = null;
        }
        if (self.scm.changes) |view| view.blurInput();
        if (self.range_highlights) |highlights| highlights.removeHighlightRange();
        if (self.breadcrumbs.activeControl()) |control| control.setFocused(false);
        self.statusbar.main_part.clearFocus();
        if (self.search_window.view) |view| view.blur();
    }

    pub fn focusStatusBar(self: *TerminalWorkbench) void {
        if (!self.geometry().statusBarVisible()) return;
        self.setFocus(.statusbar);
        self.updateProblemsHighlight();
        if (self.range_highlights) |highlights| highlights.removeHighlightRange();
        if (self.breadcrumbs.activeControl()) |control| control.setFocused(false);
        if (self.statusbar.main_part.focusedHandle() == null) {
            self.statusbar_api.focus(true);
            if (self.statusbar.main_part.focusedHandle() == null) {
                _ = self.statusbar.main_part.focusNextEntry();
            }
        }
        if (self.activeTab()) |tab| tab.focusEditor();
        if (self.search_window.view) |view| view.blur();
    }

    fn ensureProblemsView(self: *TerminalWorkbench) !void {
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
    pub fn showProblems(self: *TerminalWorkbench) !void {
        try markers_contribution.show(self.views_api);
    }

    pub fn toggleProblems(self: *TerminalWorkbench) !void {
        try markers_contribution.toggle(self.views_api);
    }

    fn problemsVisible(self: *const TerminalWorkbench) bool {
        return self.geometry().panelShown() and std.mem.eql(u8, self.geometry().activePanelId(), PROBLEMS_CONTAINER_ID);
    }

    fn problemsFocused(self: *const TerminalWorkbench) bool {
        return self.focus == .problems and self.problemsVisible();
    }

    pub fn hidePanel(self: *TerminalWorkbench) void {
        self.layout.setPartHidden(true, .panel) catch {};
    }

    /// Native mounting and focus, behind IPaneCompositePartService.
    fn openNativePaneComposite(context: *anyopaque, id: []const u8, location: views_mod.ViewContainerLocation, focus: bool) !bool {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        switch (location) {
            .sidebar => {
                try self.openActivity(id, focus);
                return true;
            },
            .panel => return self.openPanelContainerWithFocus(id, focus),
            .auxiliary_bar => return false,
        }
    }

    pub fn openPanelContainer(self: *TerminalWorkbench, id: []const u8) !bool {
        return self.openPanelContainerWithFocus(id, true);
    }

    fn openPanelContainerWithFocus(self: *TerminalWorkbench, id: []const u8, focus: bool) !bool {
        const was_hidden = !self.layout.isVisible(.panel);
        if (!try self.panel_part.openPaneCompositeWithFocus(id, focus)) return false;
        if (was_hidden) try self.layout.onPanelOpened();
        try self.syncPanelContainerVisibility();
        if (std.mem.eql(u8, id, PROBLEMS_CONTAINER_ID)) {
            try self.ensureProblemsView();
            if (focus) self.setFocus(.problems);
        } else if (focus and std.mem.eql(u8, id, @import("../vs/workbench/services/output/common/output.zig").OUTPUT_VIEW_ID)) {
            self.setFocus(.output);
        } else if (focus and std.mem.eql(u8, id, BulkEditPane.ID)) {
            self.setFocus(.bulk_edit);
        } else if (focus and std.mem.eql(u8, id, TERMINAL_CONTAINER_ID)) {
            self.setFocus(.terminal);
        }
        if (focus) {
            self.statusbar.main_part.clearFocus();
            if (self.breadcrumbs.activeControl()) |control| control.setFocused(false);
            if (self.search_window.view) |view| view.blur();
        }
        self.updateProblemsHighlight();
        self.layoutAll();
        return true;
    }

    /// Keeps the composite-bar title items in sync with `hideIfEmpty`: a
    /// container is listed while it has content, or while it is the active
    /// container (opening an empty Problems view re-shows its title).
    fn outputViewChanged(context: *anyopaque) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.syncPanelContainerVisibility() catch {};
        self.requestFrame();
    }

    fn syncPanelContainerVisibility(self: *TerminalWorkbench) !void {
        const stats = if (self.marker_service) |service| service.getStatistics() else markers_mod.MarkerStatistics{};
        const problems_has_content = stats.errors + stats.warnings + stats.infos > 0;
        const problems_active = std.mem.eql(u8, self.geometry().activePanelId(), PROBLEMS_CONTAINER_ID);
        _ = try self.panel_part.pane.setPaneCompositeVisible(PROBLEMS_CONTAINER_ID, problems_has_content or problems_active);

        const output_id = @import("../vs/workbench/services/output/common/output.zig").OUTPUT_VIEW_ID;
        _ = try self.panel_part.pane.setPaneCompositeVisible(output_id, self.output_service.channels.items.len > 0 or std.mem.eql(u8, self.geometry().activePanelId(), output_id));

        const terminals = if (self.terminal_service) |service| service.count() else 0;
        const terminal_active = std.mem.eql(u8, self.geometry().activePanelId(), TERMINAL_CONTAINER_ID);
        _ = try self.panel_part.pane.setPaneCompositeVisible(TERMINAL_CONTAINER_ID, terminals > 0 or terminal_active);
        const bulk_active = std.mem.eql(u8, self.geometry().activePanelId(), BulkEditPane.ID);
        const bulk_has_input = if (self.bulk_edit_preview) |*preview| preview.hasInput() else false;
        _ = try self.panel_part.pane.setPaneCompositeVisible(BulkEditPane.ID, bulk_active or bulk_has_input);
    }

    /// Keeps the editor range highlight in sync with the Problems selection.
    /// The highlight is only shown while Problems owns focus, matching the
    /// upstream `updateRangeHighlights` rule.
    pub fn updateProblemsHighlight(self: *TerminalWorkbench) void {
        const highlights = self.range_highlights orelse return;
        const view = if (self.problems_view) |*value| value else return highlights.removeHighlightRange();
        view.updateRangeHighlights(self.problemsFocused(), if (self.activeTab()) |tab| tab.editor else null, highlights, self.io);
    }

    pub fn setTerminalProfileStorage(self: *TerminalWorkbench, user_data_dir: []const u8) !void {
        try self.terminal_tabbed_view.setProfileStorage(self.allocator, self.io, user_data_dir);
    }

    pub fn terminalFocused(self: *const TerminalWorkbench) bool {
        return self.focusedTerminal() != null;
    }

    pub fn ensureTerminalService(self: *TerminalWorkbench) !*TerminalService {
        if (self.terminal_service) |service| return service;
        const service = try TerminalService.init(self.allocator, self.io, .{
            .workspace_root = self.workspaceFolderPath(),
            .configuration = self.configuration,
            .multi_root = self.workspace.getWorkspace().folders.items.len > 1,
        });
        try self.attachTerminalService(service);
        return service;
    }

    pub fn attachTerminalService(self: *TerminalWorkbench, service: *TerminalService) !void {
        errdefer service.deinit();
        self.terminal_focus_subscription = try service.group.on_did_change_active_instance.listenSignal(self, updatePartFocus);
        errdefer {
            self.terminal_focus_subscription.?.dispose();
            self.terminal_focus_subscription = null;
        }
        if (self.context_keys != null) try self.terminal_context.attach(service);
        self.terminal_service = service;
    }

    pub fn showTerminal(self: *TerminalWorkbench) !void {
        const service = try self.ensureTerminalService();
        if (service.count() == 0) _ = try service.create();
        self.terminal_tabbed_view.setListFocused(false);
        _ = try self.openPanelContainer(TERMINAL_CONTAINER_ID);
        self.revealActiveTerminalTab();
    }

    pub fn toggleTerminal(self: *TerminalWorkbench) !void {
        try self.terminal_action_services.run(.toggle);
    }

    fn terminalConfig(self: *const TerminalWorkbench) terminal_configuration.Config {
        return terminal_configuration.Config.load(self.configuration);
    }

    pub fn focusedTerminal(self: *const TerminalWorkbench) ?*terminal_service_mod.TerminalInstance {
        if (self.focus == .terminal and self.terminalVisible()) return self.terminal_tabbed_view.focusedInstance(self.terminal_service.?);
        if (self.focus != .editor) return null;
        const pane = self.part.viewForGroup(self.service.activeGroup()) orelse return null;
        const tab = pane.activeTab() orelse return null;
        return tab.terminalInstance();
    }

    pub fn newTerminal(self: *TerminalWorkbench) !void {
        try self.terminal_action_services.run(.new);
    }

    pub fn launchTerminalProcess(self: *TerminalWorkbench, name: []const u8, executable: []const u8, args: []const []const u8, cwd: ?[]const u8) !*terminal_service_mod.TerminalInstance {
        return self.terminal_action_services.launchProcess(name, executable, args, cwd);
    }

    pub fn newPanelTerminal(self: *TerminalWorkbench) !void {
        try self.terminal_action_services.newPanelTerminal();
    }

    fn openTerminalEditorWithProfile(context: *anyopaque, profile: terminal_platform.ITerminalProfile) !void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        const pane = self.activePane() orelse return error.GroupPaneMissing;
        const service = try self.ensureTerminalService();
        _ = try service.createEditorWithProfile(self.view_factory, pane, profile, true);
        self.revealTerminalEditor();
    }

    pub fn createTerminalInEditor(self: *TerminalWorkbench, pane: *GroupPane, parent: ?*terminal_service_mod.TerminalInstance) !*Tab {
        const service = try self.ensureTerminalService();
        const tab = try service.createEditor(self.view_factory, pane, parent);
        self.revealTerminalEditor();
        return tab;
    }

    fn revealTerminalEditor(self: *TerminalWorkbench) void {
        self.layoutAll();
        self.focusEditor();
    }

    pub fn openTerminalEditorToSide(self: *TerminalWorkbench, parent: ?*terminal_service_mod.TerminalInstance) !void {
        try self.terminal_action_services.openEditorToSide(parent);
    }

    pub fn movePanelInstanceToEditor(self: *TerminalWorkbench, service: *TerminalService, pane: *GroupPane, index: usize) !void {
        try service.moveToEditor(self.view_factory, pane, index);
        try self.revealTerminalEditorMoved(true);
    }

    pub fn revealTerminalEditorMoved(self: *TerminalWorkbench, moved: bool) !void {
        if (moved) {
            if (self.terminal_service.?.count() == 0 and self.terminalPanelActive()) self.hidePanel();
            try self.syncPanelContainerVisibility();
        }
        self.revealTerminalEditor();
    }

    fn moveTerminalToPanel(self: *TerminalWorkbench, pane: *GroupPane, tab: *Tab) !void {
        if (tab.terminal_input == null) return;
        const service = self.terminal_service orelse return;
        try service.moveToTerminalView(pane, tab, self.closeEditorHost());
        try self.showTerminal();
    }

    pub fn killTerminal(self: *TerminalWorkbench) !void {
        try self.terminal_action_services.run(.kill);
    }

    pub fn killPanelTerminal(self: *TerminalWorkbench, index: usize) !void {
        const service = self.terminal_service orelse return;
        service.kill(index);
        try self.onPanelTerminalsRemoved(service);
    }

    pub fn onPanelTerminalsRemoved(self: *TerminalWorkbench, service: *TerminalService) !void {
        if (service.count() == 0) {
            if (self.terminalPanelActive() and self.terminalConfig().hide_on_last_closed) self.hidePanel();
            try self.syncPanelContainerVisibility();
        }
        self.layoutAll();
        self.revealActiveTerminalTab();
    }

    pub fn focusPanelPane(self: *TerminalWorkbench, next: bool) bool {
        return self.terminal_action_services.focusPane(next);
    }

    pub fn focusTerminalListRow(self: *TerminalWorkbench, next: bool) void {
        const service = self.terminal_service orelse return;
        self.terminal_tabbed_view.focusListRow(service, self.geometry().panelRect(), next);
    }

    pub fn terminalPanelActive(self: *const TerminalWorkbench) bool {
        return self.geometry().panelShown() and std.mem.eql(u8, self.geometry().activePanelId(), TERMINAL_CONTAINER_ID);
    }

    fn revealActiveTerminalTab(self: *TerminalWorkbench) void {
        const service = self.terminal_service orelse return;
        self.terminal_tabbed_view.revealActive(service, self.geometry().panelRect());
    }

    pub fn focusTerminal(self: *TerminalWorkbench) !void {
        try self.terminal_action_services.run(.focus);
    }

    pub fn focusNextTerminal(self: *TerminalWorkbench) void {
        self.terminal_action_services.run(.focus_next) catch {};
    }

    pub fn focusPreviousTerminal(self: *TerminalWorkbench) void {
        self.terminal_action_services.run(.focus_previous) catch {};
    }

    pub fn terminalAcceptsPaste(self: *const TerminalWorkbench) bool {
        return self.terminalFocused() and self.context_menu_service.current == null and !self.quick_access.isOpen() and !self.isDialogOpen();
    }

    pub fn splitTerminalTabs(self: *TerminalWorkbench, index: usize) !void {
        const service = self.terminal_service orelse return;
        try service.splitSelectedTabs(index);
        try self.showTerminal();
    }

    pub fn killTerminalTabs(self: *TerminalWorkbench, index: usize) !void {
        const service = self.terminal_service orelse return;
        service.killSelectedTabs(index);
        try self.onPanelTerminalsRemoved(service);
    }

    fn showTerminalRename(self: *TerminalWorkbench, instance: *terminal_service_mod.TerminalInstance) !void {
        const service = self.terminal_service orelse return;
        try terminal_actions.showRenamePicker(service, self.quick_access.inputService(), instance);
    }

    pub fn terminalCount(self: *const TerminalWorkbench) usize {
        const service = self.terminal_service orelse return 0;
        return service.instanceCount();
    }

    pub fn disposeExitedTerminal(self: *TerminalWorkbench, instance: *terminal_service_mod.TerminalInstance) !void {
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

    fn reportTerminalExit(exit: @import("../vs/platform/terminal/node/pty.zig").Exit) void {
        if (exit.code) |code| {
            if (code != 0) std.log.scoped(.terminal).warn("Terminal process exited with code {d}", .{code});
        }
        if (exit.signal) |number| std.log.scoped(.terminal).warn("Terminal process exited on signal {d}", .{number});
    }

    pub fn layoutAll(self: *TerminalWorkbench) void {
        const override = if (self.layout.isZenModeActive()) self.zenModeConfiguration().show_tabs else null;
        self.part.handleChangedPartOptions(self.configuration, override);
        self.hovered_sash = null;
        self.layout.layoutTerminal(self.geometry());
        self.syncTerminalSize();
    }

    pub fn syncTerminalSize(self: *TerminalWorkbench) void {
        const service = self.terminal_service orelse return;
        if (!self.terminalVisible()) return;
        self.terminal_tabbed_view.layoutInstances(self.geometry().panelRect(), service);
    }

    fn paneExists(self: *const TerminalWorkbench, pane: *GroupPane) bool {
        for (self.part.group_views.items) |candidate| {
            if (candidate == pane) return true;
        }
        return false;
    }

    fn collapseEmptyPane(self: *TerminalWorkbench, pane: *GroupPane) void {
        self.part.collapseGroup(pane, self.groupTransferHost());
    }

    fn activeGroup(self: *TerminalWorkbench) *editor_groups.EditorGroup {
        return self.service.activeGroup();
    }

    fn paneForGroup(self: *TerminalWorkbench, group: *editor_groups.EditorGroup) ?*GroupPane {
        return self.part.viewForGroup(group);
    }

    pub fn activePane(self: *TerminalWorkbench) ?*GroupPane {
        return self.part.activeView();
    }

    /// First workspace folder, used for the extension host's workspace data.
    pub fn workspaceFolderPath(self: *TerminalWorkbench) ?[]const u8 {
        const folders = self.workspace.getWorkspace().folders.items;
        if (folders.len == 0) return null;
        return folders[0].resource;
    }

    pub fn activeTab(self: *TerminalWorkbench) ?*Tab {
        const pane = self.activePane() orelse return null;
        return pane.activeTab();
    }

    pub fn tabCount(self: *TerminalWorkbench) usize {
        return (editor_service_mod.EditorService{ .part = self.part }).tabCount();
    }

    pub fn groupCount(self: *const TerminalWorkbench) usize {
        return self.service.count();
    }

    pub const OpenOptions = editor_service_mod.OpenOptions;

    /// Opens a path through the editor-groups service. If the resource is
    /// already open in another group, the service reveals that group and the
    /// newly created input is discarded.
    /// Creates the shared language-feature and marker services. Idempotent;
    /// app startup calls it before the extension host and JSON client attach.
    pub fn enableLanguageFeatures(self: *TerminalWorkbench) !void {
        if (self.language_features != null) return;
        try self.ensureConfiguration();
        const features = try self.allocator.create(LanguageFeaturesService);
        errdefer self.allocator.destroy(features);
        features.* = LanguageFeaturesService.init(self.allocator);
        errdefer features.deinit();
        const textual_highlights = try @import("../vs/editor/contrib/wordHighlighter/browser/textualHighlightProvider.zig").TextualMultiDocumentHighlightFeature.create(self.allocator, features.interface());
        errdefer textual_highlights.dispose();
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
        self.outline_creator.?.models.attachWindow(&self.window_events);
        self.code_lens_cache = try self.instantiation.invokeFunction(@import("../vs/editor/contrib/codelens/browser/codeLensCache.zig").getCodeLensCache, .{});
        self.language_features = features;
        self.marker_service = marker_service;
        self.marker_decorations = marker_decorations;
        self.marker_navigation = .{ .allocator = self.allocator, .markers = marker_service, .configuration = self.configuration_api };
        self.marker_navigation_api = self.marker_navigation.?.interface();
        _ = try self.services.set(@import("../vs/editor/contrib/gotoError/browser/markerNavigationService.zig").marker_navigation_service_id, &self.marker_navigation_api.?);
        self.word_completion_provider = word_provider;
        self.snippet_registration = snippets;
        self.word_completion_registration = words;
        self.textual_highlight_feature = textual_highlights;
        self.marker_listener = listener;
        if (self.markers_status) |status| status.attach(marker_service);
        if (self.problems_view) |*view| view.setService(marker_service);
        if (self.outline_view) |view| try view.attachMarkerService(marker_service);

        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.multi_diff) |multi| {
                    for (multi.widget.impl.manager.items) |managed| if (managed.binding()) |binding| if (binding.editor) |widget| {
                        self.attachMultiDiffLanguageServices(widget);
                        if (widget.breadcrumbs_factory == null) {
                            const factory = @import("../vs/editor/contrib/diffEditorBreadcrumbs/browser/contribution.zig").Factory.create(self.allocator, features.interface(), self.outline_creator.?.models) catch continue;
                            widget.attachBreadcrumbs(factory) catch {};
                        }
                    };
                    continue;
                }
                tab.editor.attachLanguageServices(features, marker_service, marker_decorations);
                if (tab.diff) |diff| {
                    diff.widget.original_editor.attachLanguageServices(features, marker_service, marker_decorations);
                    tab.attachDiffBreadcrumbs(features, self.outline_creator.?.models);
                }
                tab.attachLanguageRegistry(features);
                self.attachLanguageContributionServices(tab);
            }
        }
    }

    fn providerCommandHost(self: *TerminalWorkbench) @import("../vs/editor/common/languages.zig").CommandHost {
        return .{ .context = self, .execute = struct {
            fn execute(context: *anyopaque, command: @import("../vs/editor/common/languages.zig").Command) !void {
                const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                const registered = host.commands.get(command.id) orelse return error.CommandNotFound;
                if (command.arguments) |args| {
                    try registered.executeWithArgument(@import("../vs/platform/commands/common/commands.zig").CommandArgument.from(std.json.Value, &args));
                } else try registered.execute();
            }
        }.execute };
    }

    fn codeActionServices(self: *TerminalWorkbench, features: *LanguageFeaturesService) @import("../vs/editor/contrib/codeAction/browser/codeActionController.zig").Services {
        const configuration = self.instantiation.invokeFunction(struct {
            fn get(accessor: @import("../vs/platform/instantiation/common/instantiation.zig").ServicesAccessor) !@import("../vs/editor/common/services/textResourceConfiguration.zig").ITextResourceConfigurationService {
                return (try accessor.get(@import("../vs/editor/common/services/textResourceConfiguration.zig").text_resource_configuration_service_id)).*;
            }
        }.get, .{}) catch null;
        return .{ .registry = &features.code_action_provider, .markers = self.marker_service, .window = &self.window_events, .action_widget = self.action_widget_api, .bulk_edit = self.bulk_edit_api, .commands = self.providerCommandHost(), .configuration = configuration };
    }

    fn attachLanguageContributionServices(self: *TerminalWorkbench, tab: *Tab) void {
        tab.attachHoverServices((editor_service_mod.EditorOpening.OpenerAdapter{ .opening = &self.editor_opening }).interface(), .{ .menus = &self.menu_service, .parent_context = self.core.context_keys.getContext() });
        const features = self.language_features orelse return;
        tab.attachCodeActionServices(self.codeActionServices(features));
        if (self.markerNavigationServices()) |services| tab.attachMarkerNavigationServices(services);
        const cache = self.code_lens_cache orelse return;
        tab.attachCodeLensServices(features, cache, self.providerCommandHost(), &self.window_events);
    }

    fn attachMultiDiffLanguageServices(self: *TerminalWorkbench, widget: *@import("../vs/workbench/browser/parts/editor/editorPane.zig").DiffWidget) void {
        const features = self.language_features orelse return;
        widget.original_editor.attachLanguageServices(features, self.marker_service, self.marker_decorations);
        widget.modified_editor.attachLanguageServices(features, self.marker_service, self.marker_decorations);
        widget.attachNativeLanguageServices(.{ .features = features, .cache = self.code_lens_cache, .commands = self.providerCommandHost(), .code_actions = self.codeActionServices(features), .opener = (editor_service_mod.EditorOpening.OpenerAdapter{ .opening = &self.editor_opening }).interface(), .hover_menus = .{ .menus = &self.menu_service, .parent_context = self.core.context_keys.getContext() }, .marker_navigation = self.markerNavigationServices(), .window = &self.window_events });
    }

    fn markerNavigationServices(self: *TerminalWorkbench) ?@import("../vs/editor/contrib/gotoError/browser/gotoError.zig").Services {
        const navigation = self.marker_navigation_api orelse return null;
        return .{ .marker_navigation = navigation, .editors = self.code_editor_api, .opener = (editor_service_mod.EditorOpening.OpenerAdapter{ .opening = &self.editor_opening }).interface(), .window = &self.window_events, .menus = &self.menu_service, .context_keys = self.core.context_keys.getContext() };
    }

    fn onMarkersChanged(_: MarkerChangeEvent, self: *TerminalWorkbench) !void {
        try self.syncPanelContainerVisibility();
    }

    /// Applies declarative language/grammar contributions to the open tabs and
    /// to tabs opened later.
    pub fn setDeclarativeExtensions(self: *TerminalWorkbench, registry: *const extensions_registry.Registry) void {
        if (self.declarative == registry) return;
        self.snippet_provider.setCatalog(registry);
        self.declarative = registry;
        if (self.ensureThemeService()) |service| service.setFileIconThemeRegistry(registry) else |_| {}
        self.applyExtensionDefaults(registry) catch {};
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| tab.editor.applyDeclarativeExtensions(registry) catch {};
        }
    }

    fn applyExtensionDefaults(self: *TerminalWorkbench, catalog: *const extensions_registry.Registry) !void {
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
    pub fn ensureConfigurationReady(self: *TerminalWorkbench) void {
        self.ensureConfiguration() catch {};
    }

    /// Registers `contributes.configuration` defaults from one extension
    /// manifest and reloads the effective configuration.
    pub fn registerExtensionConfiguration(self: *TerminalWorkbench, manifest: std.json.Value, extension_id: []const u8) void {
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
    pub fn configurationData(self: *TerminalWorkbench, arena: Allocator) !std.json.Value {
        self.ensureConfigurationReady();
        const config = self.configuration orelse return .null;
        return config.getConfigurationData(arena);
    }

    pub fn configureJsonLanguage(self: *TerminalWorkbench) void {
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
    pub fn jsonSchemasValue(self: *TerminalWorkbench) ?*const std.json.Value {
        const config = self.configuration orelse return null;
        return config.getValue("json.schemas", .{});
    }

    pub fn setJsonLanguageClient(self: *TerminalWorkbench, client: ?*json_language.Client) void {
        if (self.json_client != client) {
            if (self.json_client) |previous| previous.attachWindow(null);
            if (client) |value| value.attachWindow(&self.window_events);
        }
        self.json_client = client;
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                tab.editor.setJsonLanguageClient(client);
            }
        }
    }

    // --- begin git / source control

    fn onActiveScmRepositoryChanged(active: ?@import("../vs/workbench/contrib/scm/common/scm.zig").ActiveRepository, self: *TerminalWorkbench) !void {
        self.git_model.setActiveRepository(if (active) |entry| entry.repository.id else null);
    }

    fn deinitGit(self: *TerminalWorkbench) void {
        self.git_file_provider.detachRepository();
        self.scm.detachProvider();
        self.git_model.deinit();
    }

    /// Creates the git CLI/service, the SCM provider/view and the quick-diff
    /// controller for the workspace folder. A missing git binary, a disabled
    /// `git.enabled` or a non-repository leaves the editor untouched.
    pub fn initGit(self: *TerminalWorkbench) !void {
        try self.git_model.bindWorkspace(self.workspace, self.editor_api, .{ .context = self, .open_repository = scanGitRepository, .close_repository = closeGitRepository });
        for (self.workspace.getWorkspace().folders.items) |folder| {
            try self.openGitRepository(folder.resource);
        }
    }

    fn discoverGitResourceRepository(context: *anyopaque, path: []const u8) !void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        // The Git filesystem provider implicitly opens repositories only when
        // there are no workspace folders (the native equivalent of an empty
        // editor window). Normal workspaces use their discovered repositories.
        if (self.workspaceFolderPath() != null) return;
        try self.openGitRepository(path);
    }

    fn captureGitResourceRepository(context: *anyopaque, path: []const u8) !?*@import("../extensions/git/src/model.zig").RepositoryOpenRequest {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        if (self.workspaceFolderPath() != null) return null;
        return self.git_model.captureRepositoryOpen(path, self.gitOpenOptions());
    }

    fn publishGitResourceRepository(context: *anyopaque, request: *@import("../extensions/git/src/model.zig").RepositoryOpenRequest) !void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        if (try self.git_model.publishRepositoryOpen(request, self.gitOpenOptions())) |provider| try self.registerOpenedGitRepository(provider);
    }

    fn scanGitRepository(context: *anyopaque, root: []const u8) !void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        try self.git_model.requestRepositoryOpen(root, self.gitOpenOptions(), .{ .context = self, .publish = publishGitResourceRepository });
    }

    fn closeGitRepository(context: *anyopaque, provider: *@import("../extensions/git/src/repository.zig").Repository) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.git_file_provider.detachSingleRepository(provider);
        self.scm.unregisterProvider(provider.interface());
        self.git_model.closeRepository(provider);
    }

    fn gitOpenOptions(self: *TerminalWorkbench) @import("../extensions/git/src/model.zig").Model.OpenOptions {
        return .{
            .io = self.io,
            .configuration = self.configuration,
            .context_keys = if (self.context_keys) |keys| keys.interface() else null,
            .window = &self.window_events,
            .host_service = self.host_api,
            .host = .{ .context = self, .open_change = providerOpenChange, .refresh = scmRefresh },
            .on_disabled = gitDisabled,
            .on_disabled_context = self,
            .scan_repository = scanGitRepository,
            .notifications = self.notification_api,
        };
    }

    fn openGitRepository(self: *TerminalWorkbench, root: []const u8) !void {
        const provider = (try self.git_model.openRepository(root, self.gitOpenOptions())) orelse return;
        try self.registerOpenedGitRepository(provider);
    }

    fn registerOpenedGitRepository(self: *TerminalWorkbench, provider: *@import("../extensions/git/src/repository.zig").Repository) !void {
        const scm_api = try self.scm.ensureService();
        if (scm_api.getRepository(provider.id) != null) return;
        const first = self.scm.changes == null;
        errdefer {
            if (first) self.scm.detachProvider();
            self.git_file_provider.detachSingleRepository(provider);
            self.git_model.closeRepository(provider);
        }
        try self.git_file_provider.attachRepository(provider, &self.window_events, self.host_api);
        const quick_providers = provider.quickDiffProviders();
        if (!first) {
            try self.scm.registerProvider(provider.interface(), &quick_providers);
            if (self.file_watcher_service) |files_service| provider.watch(files_service) catch {};
            return;
        }
        try self.scm.attachProvider(provider.interface(), &quick_providers, .{
            .editors = .{ .part = self.part },
            .text_model_service = self.text_model_api,
            .view_factory = self.view_factory,
            .quick_diff_menu = .{ .menus = &self.menu_service, .parent_context = self.core.context_keys.getContext() },
            .activity_service = &self.activity_service,
            .statusbar_service = &self.statusbar,
            .window = &self.window_events,
            .configuration = self.configuration,
            .changes_host = .{
                .context = self,
                .open_change = scmViewOpen,
                .open_group_changes = struct {
                    fn run(context: *anyopaque, group: *const @import("../vs/workbench/contrib/scm/common/scm.zig").ISCMResourceGroup) !void {
                        const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                        const command = @import("../extensions/git/src/commands.zig").CommandContribution.multiDiffGroupCommandId(group) orelse return;
                        _ = try host.commands.platform.executeWithArgument(command, @import("../vs/platform/commands/common/commands.zig").CommandArgument.from(@import("../vs/workbench/contrib/scm/common/scm.zig").ISCMResourceGroup, group));
                    }
                }.run,
                .editor_service = self.editor_api,
                .resource_action = scmViewResourceAction,
                .refresh = scmRefresh,
                .focus_editor = scmFocusEditor,
                .commit = scmViewCommit,
                .context_menu = self.context_menu_api,
                .views_service = self.views_api,
                .branch_action = scmBranchAction,
                .status = scmViewStatus,
            },
            .quick_input = self.quick_access.inputService(),
            .history_host = .{
                .context = self,
                .open_change = historyOpenChange,
                .open_changes = historyOpenChanges,
                .status = scmViewStatus,
                .focus_editor = scmFocusEditor,
            },
        });
        self.scm.attachHistoryProvider(provider.interface(), self.theme_palette);
        if (self.scm.changes) |view| {
            try view.registerList(&self.lists);
            view.setThemeColors(self.theme_palette);
        }
        if (self.scm.history) |view| try view.registerList(&self.lists);

        try self.scm.attachContainer(&self.sidebar_part, &self.view_descriptor_service, self.explorer_panes.?, provider.historyProvider() != null);

        if (self.file_watcher_service) |files_service| provider.watch(files_service) catch {};
    }

    /// Re-reads git status, the SCM rows, the quick-diff baselines, the
    /// branch/status entry and the activity badge.
    pub fn refreshGitStatus(self: *TerminalWorkbench) void {
        for (self.git_model.repositories()) |provider| {
            provider.refresh() catch {};
            if (provider.refreshHistoryRefs(true) and provider == self.git_model.repository) {
                if (self.scm.history) |view| view.onHistoryItemRefsChanged(true);
            }
        }
    }

    /// Opens a diff between two refs of `path`. `working` uses the open buffer
    /// (including unsaved edits) when the file is open, otherwise the file on
    /// disk. `empty` produces the untracked/deleted side.
    pub fn openDiff(self: *TerminalWorkbench, path: []const u8, left_ref: DiffRef, right_ref: DiffRef) !void {
        try self.git_commands.openDiff(path, left_ref, right_ref);
    }

    fn openSnapshotDiff(
        self: *TerminalWorkbench,
        path: []const u8,
        source: @import("../vs/editor/browser/widget/diffEditor/diffProviderFactoryService.zig").SnapshotSource,
        left_label: []const u8,
        right_label: []const u8,
    ) !void {
        try self.editor_opening.requestOpenSnapshotDiff(if (self.configuration) |config| config.interface() else null, path, source, left_label, right_label);
    }

    fn gitDisabled(context: ?*anyopaque, reason: []const u8) void {
        const raw_context = context orelse return;
        const self: *TerminalWorkbench = @ptrCast(@alignCast(raw_context));
        self.setStatusHint("Source Control disabled: {s}", .{reason});
    }

    fn providerOpenChange(context: *anyopaque, provider: *repository_mod.Repository, resource: *repository_mod.GitScmResource) anyerror!void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        return self.git_commands.commandsFor(provider).openChange(resource);
    }

    fn scmViewOpen(_: *anyopaque, resource: *scm_common.ISCMResource) !void {
        try resource.open(false);
    }

    fn scmViewResourceAction(context: *anyopaque, action: scm_view_mod.ResourceAction, resource: *scm_common.ISCMResource) anyerror!void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.git_commands.runResourceAction(action, resource);
    }

    fn scmRefresh(context: *anyopaque) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.refreshGitStatus();
    }

    fn scmFocusEditor(context: *anyopaque) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.focusEditor();
    }

    fn scmViewCommit(context: *anyopaque, message: []const u8, action: scm_view_mod.CommitAction) anyerror!void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        try (try self.git_commands.commands()).commit(message, action);
    }

    fn scmViewStatus(context: *anyopaque, message: []const u8) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.setStatusHint("{s}", .{message});
    }

    fn scmBranchAction(context: *anyopaque, action: scm_view_mod.BranchAction) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.git_commands.runBranchAction(action);
    }

    fn onScmRemoteAction(context: *anyopaque) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.refreshGitStatus();
        if (self.scm.history) |view| view.refresh(.reload) catch {};
    }

    fn scmChangesRenderBody(
        context: *anyopaque,
        grid: *ui.CellGrid,
        rect: ui.Rect,
        focused: bool,
    ) anyerror!void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        const view = self.scm.changes orelse return;
        try view.render(grid, rect, focused, .{
            .show_header = false,
            .cell_borders = self.part.cell_borders,
            .border_capabilities = self.part.cell_border_capabilities,
        });
    }

    fn scmChangesHandleKey(context: *anyopaque, event: *ui.KeyEvent) anyerror!bool {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        const view = self.scm.changes orelse return false;
        return view.handleKey(event);
    }

    fn scmChangesHandleMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) anyerror!bool {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        const view = self.scm.changes orelse return false;
        return view.handleMouse(@constCast(event), rect);
    }

    fn scmChangesTitleActions(context: *anyopaque) []const views_mod.TitleAction {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        const view = self.scm.changes orelse return &.{};
        return view.titleActions();
    }

    fn scmHistoryRenderBody(
        context: *anyopaque,
        grid: *ui.CellGrid,
        rect: ui.Rect,
        focused: bool,
    ) anyerror!void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        const view = self.scm.history orelse return;
        try view.render(grid, rect, focused);
    }

    fn scmHistoryHandleKey(context: *anyopaque, event: *ui.KeyEvent) anyerror!bool {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        const view = self.scm.history orelse return false;
        return view.handleKey(event);
    }

    fn scmHistoryHandleMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) anyerror!bool {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        const view = self.scm.history orelse return false;
        return view.handleMouse(event, rect);
    }

    fn scmHistoryTitleActions(context: *anyopaque) []const views_mod.TitleAction {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        const view = self.scm.history orelse return &.{};
        return view.titleActions();
    }

    fn historyOpenChange(context: *anyopaque, item: *const scm_common_history.ISCMHistoryItem, change: *const scm_common_history.ISCMHistoryItemChange) !void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        const revision = if (self.scm.history) |view| view.itemRevision(item.*) else item.id;
        try (try self.git_commands.commands()).openHistoryChange(item, change, revision);
    }

    fn historyOpenChanges(context: *anyopaque, item: *const scm_common_history.ISCMHistoryItem, changes: []const scm_common_history.ISCMHistoryItemChange) !void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        const revision = if (self.scm.history) |view| view.itemRevision(item.*) else item.id;
        try self.git_commands.openHistoryChanges(item, changes, revision);
    }

    const ShowTabs = layout_service_mod.EditorTabsMode;

    fn boolSetting(self: *TerminalWorkbench, key: []const u8, default: bool) bool {
        const configuration = self.configuration orelse return default;
        return configuration.getBool(key, default);
    }

    fn pathForUri(allocator: Allocator, uri: []const u8) []const u8 {
        const parsed = std.Uri.parse(uri) catch return uri;
        if (!std.mem.eql(u8, parsed.scheme, "file")) return uri;
        return std_uri.fsPath(parsed, allocator) catch uri;
    }

    // --- end git / source control

    /// Borrows the app-owned extension inventory for the Extensions panel and
    /// its enablement actions. Called before the sidebar mounts the container.
    pub fn setExtensionsService(self: *TerminalWorkbench, service: *extensions_workbench_service.ExtensionsWorkbenchService) void {
        self.extensions_service = service;
        if (self.extensions_view) |contribution| contribution.setService(service) catch {};
    }

    pub fn setSidebarViewStorage(self: *TerminalWorkbench, user_data_dir: []const u8) !void {
        const state = try view_container_model_mod.ViewDescriptorsState.init(self.allocator, self.io, user_data_dir);
        if (self.view_state_storage) |old| old.deinit();
        self.view_state_storage = state;
        try self.restoreSidebarViewStates();
    }

    fn restoreSidebarViewStates(self: *TerminalWorkbench) !void {
        const state = self.view_state_storage orelse return;
        try state.restore(self.workspace.getWorkspace().folders.items, &.{ self.explorer_view_model, self.scm.view_model });
    }

    fn saveSidebarViewStates(self: *TerminalWorkbench) !void {
        const state = self.view_state_storage orelse return;
        try state.save(self.workspace.getWorkspace().folders.items, &.{ self.explorer_view_model, self.scm.view_model });
    }

    /// Snapshots the active editor's pane selection into the ported editor
    /// navigation history. Called before a jump or before an editor switch.
    pub fn recordNavigation(self: *TerminalWorkbench) void {
        self.recordNavigationWithReason(.USER);
    }

    pub fn recordNavigationWithReason(self: *TerminalWorkbench, reason: editor_mod.EditorPaneSelectionChangeReason) void {
        self.history.recordActiveNavigation(reason);
    }

    pub fn goBackInHistory(self: *TerminalWorkbench) bool {
        return self.history.goBackInHistory();
    }

    pub fn goForwardInHistory(self: *TerminalWorkbench) bool {
        return self.history.goForwardInHistory();
    }

    pub fn openPath(self: *TerminalWorkbench, path: []const u8) !void {
        return self.openPathWithOptions(path, .{});
    }

    pub fn openPreviewPath(self: *TerminalWorkbench, path: []const u8) !void {
        return self.openPathWithOptions(path, .{ .pinned = false });
    }

    fn samePath(self: *TerminalWorkbench, left: []const u8, right: []const u8) bool {
        return text_files.samePath(self.allocator, self.io, left, right);
    }

    pub fn findOpenInput(self: *TerminalWorkbench, path: []const u8) ?*FileEditorInput {
        return (editor_service_mod.EditorService{ .part = self.part }).findOpenFileInput(self.io, path);
    }

    pub fn findOpenImageInput(self: *TerminalWorkbench, path: []const u8) ?*ImagePreviewEditorInput {
        return (editor_service_mod.EditorService{ .part = self.part }).findOpenImageInput(self.io, path);
    }

    pub fn openPathWithOptions(self: *TerminalWorkbench, path: []const u8, options: OpenOptions) !void {
        try self.editor_opening.openPathWithOptions(path, options);
    }

    /// Window-owned asynchronous execution. Detached reads/decodes are sent
    /// to the backing worker without moving editor state off the window thread.
    pub fn asyncIo(self: *const TerminalWorkbench) Io {
        return self.async_io;
    }

    /// Interactive open: reads/decodes on the async Io and applies the result
    /// on read completion. The synchronous `openPath` remains for startup,
    /// session restore, tests and callers that already run off the TUI thread.
    pub fn requestOpenPath(self: *TerminalWorkbench, path: []const u8) void {
        self.requestOpenPathWithOptions(path, .{});
    }

    pub fn requestOpenPathWithOptions(self: *TerminalWorkbench, path: []const u8, options: OpenOptions) void {
        self.editor_opening.requestOpenPathWithOptions(path, options);
    }

    pub fn setStatusHint(self: *TerminalWorkbench, comptime fmt: []const u8, args: anytype) void {
        const accessor = self.status_hint_accessor orelse return;
        const text = std.fmt.bufPrint(&self.status_hint_buf, fmt, args) catch return;
        accessor.update(.{ .name = "Source Control", .text = text });
    }

    fn cancelAsyncJobs(self: *TerminalWorkbench) void {
        self.editor_opening.cancel();
        if (self.theme_service) |service| service.cancelColorThemeLoad();
        self.user_keybindings.cancelReload();
        if (self.settings_watcher) |watcher| watcher.cancelReload();
        if (self.sidebar) |sidebar| sidebar.cancelLoad();
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.image_preview) |preview| preview.cancelLoad();
                if (tab.markdown_preview) |preview| preview.cancelImageJobs();
            }
        }
    }

    pub fn openActiveImageAsText(self: *TerminalWorkbench) !void {
        try media_actions.reopenActiveImageAsText(self.editor_api);
    }

    /// Opens the first definition target for the cursor. Ports the action
    /// behind upstream's `editor.action.revealDefinition` (F12 in VS Code);
    /// the terminal surfaces it as `Ctrl-]` and through the command bridge.
    pub fn revealDefinition(self: *TerminalWorkbench) !bool {
        return self.runLspAction(go_to_commands.definition.id);
    }

    pub fn revealDeclaration(self: *TerminalWorkbench) !bool {
        return self.runLspAction(go_to_commands.declaration.id);
    }

    pub fn goToTypeDefinition(self: *TerminalWorkbench) !bool {
        return self.runLspAction(go_to_commands.type_definition.id);
    }

    pub fn goToImplementation(self: *TerminalWorkbench) !bool {
        return self.runLspAction(go_to_commands.implementation.id);
    }

    pub fn goToReferences(self: *TerminalWorkbench) !bool {
        return self.runLspAction(go_to_commands.go_to_references.id);
    }

    pub fn showReferences(self: *TerminalWorkbench) !bool {
        return self.runLspAction(go_to_commands.find_references.id);
    }

    pub fn runLspAction(self: *TerminalWorkbench, id: []const u8) !bool {
        const action = go_to_commands.find(id) orelse return false;
        return self.executeSymbolNavigation(action);
    }

    pub fn executeSymbolNavigation(self: *TerminalWorkbench, action: *const go_to_commands.ActionDescriptor) !bool {
        return self.symbol_navigation.runEditorCommand(action);
    }

    fn navigateToLink(self: *TerminalWorkbench, link: languages.LocationLink) !void {
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
    }

    pub fn gotoSymbolInEditor(self: *TerminalWorkbench) !bool {
        return self.symbol_quick_access.provide();
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
    pub fn notifyEditorKeyDown(self: *TerminalWorkbench, event: *ui.KeyEvent) bool {
        const tab = self.activeTab() orelse return false;
        if (tab.isDiff() or tab.isMultiDiff() or tab.isImage()) return false;
        tab.ensureControllers() catch return false;
        const controllers = tab.controllers orelse return false;
        controllers.editor.onBeforeInteractionEvent();
        if (controllers.hover) |hover| {
            _ = self.ensureContextKeys() catch return false;
            const service = self.ensureGlobalService() catch return false;
            _ = hover.onKeyDownWithResolution(event, service.softDispatch(event.*));
        }
        return !tab.view.hasEditorFocus();
    }

    /// Shows or focuses the content hover at the cursor, matching upstream's
    /// `editor.action.showHover`.
    pub fn showHover(self: *TerminalWorkbench) !bool {
        const tab = self.activeTab() orelse return false;
        try tab.ensureControllers();
        const controllers = tab.focusedControllers() orelse return false;
        return hover_actions.showOrFocusHover(controllers.editor, .FocusIfVisible);
    }

    pub fn activateIndex(self: *TerminalWorkbench, index: usize) !void {
        try self.group_actions.activateIndex(index);
    }

    /// Closes the tab showing `path`, if any. Used by extension tab commands.
    pub fn closePath(self: *TerminalWorkbench, path: []const u8) !bool {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!self.samePath(tab.editor.path, path)) continue;
                return self.closeTab(pane, tab);
            }
        }
        return false;
    }

    pub fn switchTab(self: *TerminalWorkbench, delta: isize) !void {
        try self.group_actions.switchTab(delta);
    }

    pub fn switchGroup(self: *TerminalWorkbench, delta: isize) !void {
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
            return;
        }
    }

    pub const GroupDirection = enum { left, right, up, down };

    fn findAdjacentPane(self: *TerminalWorkbench, direction: editor_groups.GroupDirection, wrap: bool) !?*GroupPane {
        self.layoutAll();
        return self.part.findGroup(.{ .direction = direction }, self.activePane() orelse return null, wrap);
    }

    fn focusPane(_: *TerminalWorkbench, pane: *GroupPane) !void {
        if (pane.activeTab()) |tab| try tab.ensureControllers();
        pane.focus();
    }

    fn onEditorGroupsChanged(self: *TerminalWorkbench) !void {
        self.layoutAll();
        self.requestFrame();
    }

    fn onEditorPartFocus(_: void, self: *TerminalWorkbench) !void {
        const pane = self.activePane() orelse return;
        pane.syncActivePane();
        self.layoutAll();
        if (pane.activeTab()) |tab| try tab.ensureControllers();
        self.focusEditor();
    }

    /// `<C-w>h/j/k/l`: focus the nearest pane in a direction using the laid-out
    /// grid rectangles. This mirrors VS Code's directional group navigation
    /// without needing the browser grid's DOM geometry.
    pub fn navigateGroup(self: *TerminalWorkbench, direction: GroupDirection) !void {
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
    }

    /// Port of the `workbench.action.focus*Group` family. `wrap` matches
    /// upstream's focus actions, which wrap at the grid edge.
    pub fn focusGroupDirection(self: *TerminalWorkbench, direction: editor_groups.GroupDirection) !void {
        const target = try self.findAdjacentPane(direction, true) orelse return;
        try self.focusPane(target);
    }

    pub fn focusGroupLocation(self: *TerminalWorkbench, location: GroupLocation) !void {
        self.layoutAll();
        const source = self.activePane() orelse return;
        if (try self.part.findGroup(.{ .location = location }, source, true)) |view| try self.focusPane(view);
    }

    pub fn focusActiveGroup(self: *TerminalWorkbench) !void {
        const pane = self.activePane() orelse return;
        try self.focusPane(pane);
    }

    fn destroyPane(self: *TerminalWorkbench, pane: *GroupPane) void {
        self.part.destroyGroup(pane, self.groupTransferHost());
    }

    pub fn cycleGroup(self: *TerminalWorkbench) !void {
        try self.focusGroupLocation(.next);
    }

    pub fn closeAllEditors(self: *TerminalWorkbench) !void {
        try self.group_actions.closeAllEditors();
    }

    pub fn closeOtherEditors(self: *TerminalWorkbench) !void {
        try self.group_actions.closeOtherEditors();
    }

    pub fn lastEditorInGroup(self: *TerminalWorkbench) !void {
        try self.group_actions.lastEditorInGroup();
    }

    pub fn previousEditor(self: *TerminalWorkbench) !void {
        try self.group_actions.previousEditor();
    }

    pub fn revertAndCloseActiveEditor(self: *TerminalWorkbench) !void {
        try self.group_actions.revertAndCloseActiveEditor();
    }

    pub fn moveActiveEditor(self: *TerminalWorkbench, to: []const u8, by: []const u8, value: usize) !void {
        try @import("../vs/workbench/browser/parts/editor/editorCommands.zig").moveActiveEditor(&self.group_actions, to, by, value);
    }

    pub fn showExplorer(self: *TerminalWorkbench) !void {
        if (try self.showActivityById("explorer")) self.focusSidebar();
    }

    /// Preferred side-by-side split direction from
    /// `workbench.editor.openSideBySideDirection` (upstream
    /// `preferredSideBySideGroupDirection`).
    pub fn preferredSideBySideDirection(self: *TerminalWorkbench) editor_groups.GroupDirection {
        return editor_groups.preferredSideBySideGroupDirection(if (self.configuration) |config| config.interface() else null);
    }

    /// Port of `workbench.action.splitEditor`: duplicate the active editor
    /// into a new group in the preferred side-by-side direction.
    pub fn splitActive(self: *TerminalWorkbench, direction: SplitDirection) !void {
        try self.splitActiveInDirection(switch (direction) {
            .horizontal => .RIGHT,
            .vertical => .DOWN,
        });
    }

    pub fn splitActiveInDirection(self: *TerminalWorkbench, direction: editor_groups.GroupDirection) !void {
        try self.group_actions.splitActiveInDirection(direction);
    }

    fn copyTabIntoPaneWithOptions(self: *TerminalWorkbench, target: *GroupPane, tab: *Tab, options: group_mod.EditorOpenOptions) !*Tab {
        return target.copyEditor(tab, options, self.copyEditorHost());
    }

    fn groupTransferHost(self: *TerminalWorkbench) @import("../vs/workbench/browser/parts/editor/editorPart.zig").EditorPart(GroupPane).TransferHost {
        return .{
            .copy = self.copyEditorHost(),
            .move = .{ .context = self, .will_move = willMoveEditor, .discard = discardTransferPane, .focus_editor = focusEditorAfterTransfer },
            .invalidate_pane = struct {
                fn run(context: *anyopaque, pane: *GroupPane) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.editor_drop_target.invalidateDragPane(pane);
                }
            }.run,
            .clear_drag = struct {
                fn run(context: *anyopaque) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.editor_drop_target.clearTabDrag();
                }
            }.run,
            .layout = struct {
                fn run(context: *anyopaque) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.layoutAll();
                }
            }.run,
            .focus_editor = focusWindowEditor,
        };
    }

    fn copyEditorHost(self: *TerminalWorkbench) GroupPane.CopyEditorHost {
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
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.editor_configuration.applyToTab(tab);
        self.attachLanguageContributionServices(tab);
        self.instantiation.invokeFunction(@import("../vs/workbench/workbench.common.main.zig").attachDiffEditorContributions, .{tab}) catch {};
        if (!tab.isImage()) self.registerWorkingCopy(tab);
        if (self.language_features) |features| tab.attachLanguageRegistry(features);
    }

    fn copyTerminalPane(context: *anyopaque, target: *GroupPane, parent: *terminal_service_mod.TerminalInstance) !*Tab {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        return self.createTerminalInEditor(target, parent);
    }

    pub fn closeActive(self: *TerminalWorkbench) !bool {
        try self.group_actions.closeActiveEditor();
        return false;
    }

    /// Closes the active tab without the dirty confirmation. `:q!` uses this;
    /// all other close paths keep the confirmation.
    pub fn forceCloseActive(self: *TerminalWorkbench) !void {
        self.part.active_sash = null;
        self.editor_drop_target.clearTabDrag();
        const pane = self.activePane() orelse return;
        const tab = pane.activeTab() orelse return;
        try self.performCloseTab(pane, tab);
    }

    /// The group owns dirty-close confirmation; the host supplies disposal
    /// and focus at the terminal boundary.
    pub fn closeTab(self: *TerminalWorkbench, pane: *GroupPane, tab: *Tab) !bool {
        try self.group_actions.closeEditor(pane, tab);
        return false;
    }

    pub fn closeEditorHost(self: *TerminalWorkbench) GroupPane.CloseHost {
        return .{
            .context = self,
            .prepare_dialog = struct {
                fn run(context: *anyopaque) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.part.active_sash = null;
                    host.editor_drop_target.clearTabDrag();
                    host.editor_drop_target.last_tab_click = null;
                }
            }.run,
            .focus_editor = struct {
                fn run(context: *anyopaque, tab: ?*Tab) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    if (tab) |target| host.focusEditorAfterDialog(target) else host.focusActiveEditor();
                }
            }.run,
            .is_alive = struct {
                fn run(context: *anyopaque, pane: *GroupPane, tab: *Tab) bool {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    return host.paneExists(pane) and pane.indexOfTab(tab) != null;
                }
            }.run,
            .close_tab = struct {
                fn run(context: *anyopaque, pane: *GroupPane, tab: *Tab) !void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    try host.performCloseTab(pane, tab);
                }
            }.run,
            .report_error = struct {
                fn run(context: *anyopaque, err: anyerror) void {
                    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    host.reportDialogError(err);
                }
            }.run,
        };
    }

    fn reportDialogError(self: *TerminalWorkbench, err: anyerror) void {
        if (self.activeTab()) |tab| {
            tab.editor.setMessage("Close failed: {s}", .{@errorName(err)});
        }
        self.focusActiveEditor();
    }

    fn focusEditorAfterDialog(self: *TerminalWorkbench, tab: *Tab) void {
        self.focusEditor();
        tab.focusEditor();
    }

    fn focusActiveEditor(self: *TerminalWorkbench) void {
        self.focusEditor();
        if (self.activeTab()) |tab| tab.focusEditor();
    }

    pub fn reopenLastClosedEditor(self: *TerminalWorkbench) bool {
        return self.history.reopenLastClosedEditor();
    }

    /// Detaches raw editor view-event handlers before a tab destroys its
    /// editor. Upstream disposes the outline/pane before the editor; the
    /// terminal keeps one shared OutlinePane, so it must let go of the editor
    /// while the editor is still alive.
    fn detachTabViewHandlers(self: *TerminalWorkbench, tab: *Tab) void {
        if (self.context_keys != null) {
            self.workbench_context.detachEditor(tab.editor);
            if (tab.diff) |diff| self.workbench_context.detachEditor(diff.widget.original_editor);
        }
        if (self.outline_view) |view| view.detachDisposedEditor(tab.editor);
    }

    fn performCloseTab(self: *TerminalWorkbench, pane: *GroupPane, tab: *Tab) !void {
        self.editor_drop_target.invalidateDragTab(pane, tab);
        try self.part.closeEditor(pane, tab, self.groupTransferHost());
    }

    pub fn toggleExpandGroup(self: *TerminalWorkbench, pane: *GroupPane) void {
        self.part.toggleExpandGroup(pane);
    }

    pub fn ensureContextKeys(self: *TerminalWorkbench) !*context_key_mod.ContextKeyService {
        if (self.context_keys) |service| return service;
        const service = try self.allocator.create(context_key_mod.ContextKeyService);
        errdefer self.allocator.destroy(service);
        service.* = context_key_mod.ContextKeyService.init(self.allocator);
        errdefer service.deinit();
        self.configuration_context = .init(self.allocator, service, self.configuration_api);
        errdefer self.configuration_context.deinit();
        try self.configuration_context.registerListeners();
        try self.workbench_context.init(service.interface(), self.layout.interface(), &self.working_copy_service);
        errdefer self.workbench_context.deinit();
        try self.terminal_context.init(service.interface(), self.part, &self.panel_part, self.layout.interface());
        errdefer self.terminal_context.deinit();
        if (self.terminal_service) |terminal| try self.terminal_context.attach(terminal);
        try self.accessible_view.bindContextKeys(service.interface());
        try self.action_widget_service.bindContextKeys(service.interface());
        if (self.bulk_edit_preview) |*pane| try pane.bindContextKeys(service.interface());
        self.context_keys = service;
        self.commands.context_keys = service.interface();
        self.updateContextKeys();
        return service;
    }

    fn updateContextKeys(self: *TerminalWorkbench) void {
        if (self.context_keys == null) return;
        const active = self.activeTab();
        const terminal_editor = if (active) |tab| tab.terminal_input != null else false;
        const markdown_preview = if (active) |tab| tab.markdown_preview != null else false;
        const target = self.code_editor_api.getFocusedCodeEditor() orelse self.code_editor_api.getActiveCodeEditor();
        const text_editor = target != null;
        const active_diff_widget = if (active) |tab| tab.activeDiffWidget() else null;
        const multi_diff = if (active) |tab| tab.multi_diff else null;
        const geometry_value = self.geometry();
        const visible_diff = blk: {
            for (self.part.group_views.items) |pane| {
                if (pane.activeTab()) |tab| if (tab.isDiff()) break :blk true;
            }
            break :blk false;
        };
        self.workbench_context.updateWindowContext(.{
            .active_editor = target,
            .active_diff = if (active) |tab| tab.isDiff() else false,
            .active_multi_diff = multi_diff != null,
            .multi_diff_all_collapsed = if (multi_diff) |multi| multi.widget.impl.allCollapsed() else false,
            .multi_diff_render_side_by_side = if (multi_diff) |multi| multi.widget.impl.config.render_side_by_side orelse true else true,
            .multi_diff_file_list_available = if (multi_diff) |multi| multi.fileListAvailable() else false,
            .multi_diff_file_list_enabled = if (multi_diff) |multi| multi.fileListEnabled() else false,
            .multi_diff_file_list_visible = if (multi_diff) |multi| multi.fileListVisible() else false,
            .multi_diff_file_list_focused = self.focus == .editor and if (multi_diff) |multi| multi.fileListFocused() else false,
            .multi_diff_file_list_view_mode = if (multi_diff) |multi| @tagName(multi.fileListViewMode()) else "list",
            .multi_diff_file_list_position = if (multi_diff) |multi| @tagName(multi.fileListPosition()) else "right",
            .diff_original_uri = if (active_diff_widget) |widget| widget.gutter_toolbar.original_uri else "",
            .diff_modified_uri = if (active_diff_widget) |widget| widget.gutter_toolbar.modified_uri else "",
            .visible_diff = visible_diff,
            .comparing_moved_code = if (active_diff_widget) |widget| widget.view_model.moved_text_to_compare != null else false,
            .language_visible = text_editor,
            .language_id = if (target) |editor| editor.languageId() else "",
            .custom_editor_id = if (markdown_preview and active.?.file_input != null) "vscode.markdown.preview.editor" else "",
            .editor_focused = self.focus == .editor,
            .editor_tab_moves_focus = if (target) |editor| editor.getTabFocusMode() or self.tab_focus.getTabFocusMode() else self.tab_focus.getTabFocusMode(),
            .editor_text_focused = self.focus == .editor and !(if (multi_diff) |multi| multi.fileListFocused() else false) and !terminal_editor and !markdown_preview and !self.isDialogOpen() and !self.quick_access.isOpen() and !self.accessible_view.visible() and !(if (active_diff_widget) |widget| widget.accessible_viewer.visible() else false),
            .sidebar_focused = self.focus == .sidebar and geometry_value.sidebarShown(),
            .sidebar_visible = geometry_value.sidebarShown(),
            .active_activity = self.activity_bar_part.active_id orelse "",
            .search_results_focused = if (self.search_window.view) |view| view.results_focused else false,
            .statusbar_focused = self.focus == .statusbar,
            .terminal_focused = self.terminalFocused(),
            .panel_focused = (self.focus == .terminal or self.focus == .problems or self.focus == .bulk_edit or self.focus == .output) and geometry_value.panelShown(),
            .bulk_edit_preview_focused = self.focus == .bulk_edit,
            .active_panel = if (geometry_value.panelShown()) geometry_value.activePanelId() else "",
            .quick_access_open = self.quick_access.isOpen(),
            .files_picker_open = self.quick_access.isOpen() and !self.quick_access.isPickOpen(),
            .resource_scheme = if (terminal_editor) "vscode-terminal" else if (target) |editor| editor.model.uri().scheme else "file",
            .editor_read_only = if (target) |editor| editor.isReadOnly() else false,
            .legacy_editor_read_only = if (target) |editor| editor.isReadOnly() else false,
        });
    }

    fn getFileIconTheme(self: *const TerminalWorkbench) file_icon.FileIconThemeData {
        return if (self.theme_service) |service| service.getFileIconTheme() else .{};
    }

    pub fn themeColor(self: *const TerminalWorkbench, id: []const u8, fallback: [3]u8) ui.Color {
        const palette = self.theme_palette orelse return .{ .r = fallback[0], .g = fallback[1], .b = fallback[2] };
        return palette.color(id, fallback);
    }

    fn userRemovalOverrides(self: *TerminalWorkbench) []const *const resolved_keybinding_item.ResolvedKeybindingItem {
        return self.user_keybindings.removals();
    }

    fn isKnownCommand(self: *const TerminalWorkbench, command: []const u8) bool {
        if (self.commands.get(command) != null) return true;
        for (global_keybinding_rules) |rule| {
            if (std.mem.eql(u8, rule.id, command)) return true;
        }
        for (tab_keybinding_rules) |rule| {
            if (std.mem.eql(u8, rule.id, command)) return true;
        }
        return false;
    }

    fn isKnownKeybindingCommand(context: *anyopaque, command: []const u8) bool {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        return self.isKnownCommand(command);
    }

    fn onUserKeybindingsChanged(_: void, self: *TerminalWorkbench) !void {
        self.disposeKeybindingServices();
        self.applyKeybindingConsumers();
        self.requestFrame();
    }

    fn disposeKeybindingServices(self: *TerminalWorkbench) void {
        if (self.global_service) |service| {
            service.deinit();
            self.global_service = null;
        }
        if (self.tab_service) |service| {
            service.deinit();
            self.tab_service = null;
        }
    }

    fn applyKeybindingConsumers(self: *TerminalWorkbench) void {
        const removals = self.userRemovalOverrides();
        for (self.part.group_views.items) |pane| {
            if (pane.watermark) |*watermark| watermark.invalidateShortcuts();
            for (pane.tabs.items) |tab| {
                if (!tab.isDiff()) tab.editor.reloadShortcutKeybindings(removals);
            }
        }
        if (self.search_window.view) |view| view.reloadKeybindings(removals);
    }

    fn ensureThemeService(self: *TerminalWorkbench) !*theme_service_mod.ThemeService {
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

    pub fn registerThemeSources(self: *TerminalWorkbench, themes: []const extensions_registry.Theme) !void {
        try (try self.ensureThemeService()).registerThemeSources(themes);
    }

    pub fn applyThemeSettings(self: *TerminalWorkbench) void {
        self.ensureConfiguration() catch {};
        const service = self.ensureThemeService() catch return;
        service.restoreColorTheme();
    }

    fn onFileIconThemeChanged(self: *TerminalWorkbench) !void {
        self.requestFrame();
    }

    fn onColorThemeChanged(_: void, self: *TerminalWorkbench) !void {
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

    fn applyThemeToParts(self: *TerminalWorkbench, palette: ?*const theme_colors_mod.ThemeColors) void {
        editor_css.hover.registerTheme(self.editor_surface.document(), theme_colors_mod.ThemeColors.hoverTheme(palette)) catch {};
        editor_css.light_bulb.registerTheme(self.editor_surface.document(), theme_colors_mod.ThemeColors.lightBulbTheme(palette)) catch {};
        editor_css.message.registerTheme(self.editor_surface.document(), theme_colors_mod.ThemeColors.messageTheme(palette)) catch {};
        self.applyContextMenuTheme(palette);
        if (self.sidebar) |sidebar| sidebar.setThemeColors(palette);
        self.search_window.setThemeColors(palette);
        if (self.scm.changes) |view| view.setThemeColors(palette);
        if (self.scm.history) |view| view.setThemeColors(palette);
        if (self.outline_view) |view| view.setThemeColors(palette);
        self.breadcrumbs.setThemeColors(palette);
        self.dialog_handler.setThemeColors(palette);
        self.accessible_view.setThemeColors(palette);
        self.statusbar.main_part.setThemeColors(palette);
        self.quick_access.setThemeColors(palette);
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                tab.setThemeColors(palette);
                if (tab.controllers) |controllers| controllers.setThemeColors(palette);
                if (tab.markdown_preview) |preview| preview.setThemeColors(palette);
                if (tab.image_preview) |image_pane| image_pane.setThemeColors(palette);
            }
        }
    }

    fn refreshSyntaxTheme(self: *TerminalWorkbench, loaded: bool) void {
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

    fn refreshOpenViews(self: *TerminalWorkbench) void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.isDiff()) tab.view.invalidate();
            }
        }
    }

    pub fn ensureGlobalService(self: *TerminalWorkbench) !*keybinding_service.KeybindingService {
        if (self.global_service) |service| return service;
        const context = try self.ensureContextKeys();
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

    pub fn ensureTabService(self: *TerminalWorkbench) !*keybinding_service.KeybindingService {
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

    fn runTabCommand(self: *TerminalWorkbench, command: []const u8) !?TabKeyResult {
        if (std.mem.eql(u8, command, "workbench.action.closeActiveEditor")) {
            return if (try self.closeActive()) .quit else .handled;
        }
        if (std.mem.eql(u8, command, "workbench.action.nextEditor")) {
            try self.group_actions.navigateEditor(false);
            return .handled;
        }
        if (std.mem.eql(u8, command, "workbench.action.previousEditor")) {
            try self.group_actions.navigateEditor(true);
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

    pub fn requestQuit(self: *TerminalWorkbench) bool {
        if (self.isDialogOpen()) return false;
        const CloseAllEditors = @import("../vs/workbench/browser/parts/editor/editorActions.zig").CloseAllEditorsForWindow;
        if (!CloseAllEditors.hasDirtyEditors(self.part)) return true;
        CloseAllEditors.run(self.part, self.dialog_api, self.closeEditorHost(), onQuitAccepted) catch |err| {
            if (self.activeTab()) |tab| tab.editor.setMessage("Unable to open quit confirmation: {s}", .{@errorName(err)});
        };
        return false;
    }

    fn onQuitAccepted(context: *anyopaque) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.quit_requested = true;
    }

    pub fn cancelSashDrag(self: *TerminalWorkbench) bool {
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
    fn discardTab(self: *TerminalWorkbench, tab: *Tab) void {
        self.editor_tab_menus.invalidateTab(tab);
        if (self.hovered_tab == tab) self.hovered_tab = null;
        self.history.detachHistoryTab(tab);
        self.unregisterWorkingCopy(tab);
        self.detachTabViewHandlers(tab);
        tab.deinit();
    }

    fn moveTabToPane(self: *TerminalWorkbench, source: *GroupPane, dest: *GroupPane, tab: *Tab, index: ?isize) !void {
        _ = try self.moveTabToPaneWithOptions(source, dest, tab, .{ .pinned = true, .active = true, .index = index });
    }

    fn moveTabToPaneWithOptions(self: *TerminalWorkbench, source: *GroupPane, dest: *GroupPane, tab: *Tab, options: group_mod.EditorOpenOptions) !*Tab {
        return source.moveEditor(dest, tab, options, .{ .context = self, .will_move = willMoveEditor, .discard = discardTransferPane, .focus_editor = focusEditorAfterTransfer });
    }

    fn willMoveEditor(context: *anyopaque, source: *GroupPane, tab: *Tab) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.editor_drop_target.invalidateDragTab(source, tab);
    }

    fn discardTransferPane(context: *anyopaque, tab: *Tab) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.discardTab(tab);
    }

    fn focusEditorAfterTransfer(context: *anyopaque) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.setFocus(.editor);
    }

    pub fn leaveEditorHover(self: *TerminalWorkbench) void {
        if (self.activeTab()) |tab| {
            tab.hideEditorHovers();
        }
    }

    /// Clears the side bar view hover state: the Explorer row hover, the SCM
    /// pane header title action highlight and the Graph row hover. Called when
    /// pointer motion leaves the view content for the chrome or another part.
    pub fn clearSidebarViewHover(self: *TerminalWorkbench) void {
        if (self.sidebar) |sidebar| sidebar.clearHover();
        if (self.search_window.view) |view| view.clearHover();
        if (self.scm.container) |container| container.clearHover();
        if (self.scm.changes) |view| view.clearHover();
        if (self.explorer_container) |container| container.clearHover();
        if (self.scm.history) |view| view.clearHover();
        if (self.outline_view) |view| view.clearHover();
    }

    pub fn activeSidebarViewContainer(self: *const TerminalWorkbench) ?*view_pane_container_mod.ViewPaneContainer {
        const id = self.activity_bar_part.active_id orelse return null;
        return self.sidebar_part.getViewPaneContainer(id);
    }

    fn onViewContainerChanged(change: @import("../vs/workbench/services/views/browser/viewDescriptorService.zig").ViewContainerChange, self: *TerminalWorkbench) !void {
        const destination = self.sidebar_part.getViewPaneContainer(change.to.container.id) orelse return;
        _ = try self.showActivityById(change.to.container.id);
        destination.setActive(change.views[0]);
        try self.saveSidebarViewStates();
    }

    pub fn clearTabHover(self: *TerminalWorkbench) void {
        self.hovered_tab = null;
        self.hovered_pane = null;
        self.hovered_title_action_pane = null;
        self.hovered_title_toolbar_id = null;
        if (self.breadcrumbs.activeControl()) |control| control.clearHover();
    }

    fn renderWatermarkShortcuts(context: *anyopaque, watermark: *editor_group_watermark.EditorGroupWatermark) !void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
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
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.commands.execute(id) catch |err| std.log.warn("Editor shortcut {s} failed: {s}", .{ id, @errorName(err) });
    }

    pub fn watermarkShortcuts(self: *TerminalWorkbench) editor_group_view.WatermarkShortcuts {
        return .{ .context = self, .render = renderWatermarkShortcuts };
    }

    pub fn setFocus(self: *TerminalWorkbench, focus: Focus) void {
        self.focus = focus;
        self.sidebar_part.setFocused(focus == .sidebar);
        self.updatePartFocus() catch {};
    }

    fn onDialogStateChanged(self: *TerminalWorkbench) !void {
        self.pointer = .default;
        self.updatePartFocus() catch {};
        self.requestFrame();
    }

    fn onTerminalListFocus(context: *anyopaque) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.updatePartFocus() catch {};
    }

    fn updatePartFocus(self: *TerminalWorkbench) !void {
        const blocked = self.isDialogOpen() or self.quick_access.isOpen();
        self.part.setEditorFocus(!blocked and self.focus == .editor);
        if (self.bulk_edit_preview) |*pane| pane.setFocus(!blocked and self.focus == .bulk_edit);
        if (self.terminal_service) |service| {
            if (service.setFocusedInstance(if (blocked) null else self.focusedTerminal())) self.terminal_input.button_down = null;
        }
        self.updateContextKeys();
    }

    /// First workspace folder resource, or null for an empty workspace.
    fn workspaceRoot(self: *const TerminalWorkbench) ?[]const u8 {
        const folders = self.workspace.getWorkspace().folders.items;
        if (folders.len == 0) return null;
        return folders[0].resource;
    }

    /// Port of the `workbench.activityBar.location` / `.autoHide` /
    /// `.compact` configuration listener: the side bar part decides where its
    /// composite bar lives and whether the activity bar is shown at all.
    fn applyLayoutSettings(self: *TerminalWorkbench, change: ?configuration_mod.Change) void {
        const values = layout_service_mod.LayoutSettingsValues.load(self.configuration, self.workspaceRoot());
        self.layout.panel_opens_maximized = values.panel_opens_maximized;
        if (change == null) self.layout.initializePanelPosition(values.panel_position) catch {};
        if (change == null or @import("../vs/platform/configuration/common/configuration.zig").affectsConfiguration(change.?, layout_service_mod.LayoutSettings.status_bar_visible))
            self.layout.setStatusBarConfiguration(values.status_bar_visible) catch {};
        if (change == null or @import("../vs/platform/configuration/common/configuration.zig").affectsConfiguration(change.?, layout_service_mod.LayoutSettings.sidebar_position))
            self.layout.setSideBarPosition(values.sidebar_position) catch {};
        self.activity_bar_part.setCompact(values.activity_bar_compact) catch {};
        self.sidebar_part.setLayoutSettings(values) catch {};
        self.syncActivityBarVisibility() catch {};
        self.layoutAll();
    }

    /// Port of `SidebarPart.onDidChangeActivityBarLocation`: the rail is shown
    /// while the side bar does not host the composite bar. Zen mode hides the
    /// rail independently of the configured location.
    fn syncActivityBarVisibility(self: *TerminalWorkbench) !void {
        const hidden_by_zen = self.layout.isZenModeActive() and self.zenModeConfiguration().hide_activity_bar;
        const show = !hidden_by_zen and self.sidebar_part.shouldShowActivityBar();
        try self.layout.setPartHidden(!show, .activitybar);
    }

    /// Port of `getZenModeConfiguration` in `layout.ts`.
    fn zenModeConfiguration(self: *TerminalWorkbench) zen_mode_contribution.ZenModeConfiguration {
        return zen_mode_contribution.load(self.configuration, self.workspaceRoot());
    }

    pub fn toggleZenMode(self: *TerminalWorkbench, skip_layout: bool, restoring: bool) !void {
        try self.layout.toggleZenMode(skip_layout, restoring);
    }

    fn readZenModeConfiguration(context: *anyopaque) zen_mode_contribution.ZenModeConfiguration {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        return self.zenModeConfiguration();
    }

    fn centeredEditorOptions(context: *anyopaque) Layout.CenteredEditorOptions {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        return .fromEditorPart(self.part, self.configuration);
    }

    fn configuredPartVisible(context: *anyopaque, part: layout_service_mod.Parts) bool {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        return switch (part) {
            .activitybar => self.sidebar_part.shouldShowActivityBar(),
            else => self.layout.isVisible(part),
        };
    }

    fn applyZenLineNumbers(context: *anyopaque, hidden: bool) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        self.editor_configuration.setZenLineNumbers(hidden);
    }

    fn focusedLayoutPart(context: *anyopaque) layout_service_mod.Parts {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        return switch (self.focus) {
            .sidebar => .sidebar,
            .terminal, .problems, .bulk_edit, .output => .panel,
            .statusbar => .statusbar,
            .breadcrumbs, .editor => .editor,
        };
    }

    fn focusLayoutPart(context: *anyopaque, part: layout_service_mod.Parts) void {
        const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
        switch (part) {
            .sidebar => if (self.geometry().sidebarShown()) self.focusSidebar() else self.focusEditor(),
            .panel => {
                if (self.problemsVisible()) {
                    self.setFocus(.problems);
                    self.updateProblemsHighlight();
                } else if (std.mem.eql(u8, self.geometry().activePanelId(), @import("../vs/workbench/services/output/common/output.zig").OUTPUT_VIEW_ID) and self.geometry().panelShown()) {
                    self.setFocus(.output);
                } else if (std.mem.eql(u8, self.geometry().activePanelId(), BulkEditPane.ID) and self.geometry().panelShown()) {
                    self.setFocus(.bulk_edit);
                } else if (self.terminalVisible()) {
                    self.setFocus(.terminal);
                } else return self.focusEditor();
                self.statusbar.main_part.clearFocus();
                if (self.search_window.view) |view| view.blur();
            },
            .statusbar => if (self.geometry().statusBarVisible()) self.focusStatusBar() else self.focusEditor(),
            else => self.focusEditor(),
        }
    }

    pub fn ensureBreadcrumbsControl(self: *TerminalWorkbench, pane: *GroupPane) !*BreadcrumbsControl {
        return self.breadcrumbs.getControl(pane) orelse error.NoActiveTab;
    }

    fn ensureOutlineView(self: *TerminalWorkbench) !*OutlinePane {
        if (self.outline_view) |view| return view;
        const view = try OutlinePane.init(self.allocator, .{
            .context = self,
            .active_editor = outlineActiveEditor,
            .active_resource = outlineActiveResource,
            .current_position = outlineViewCurrentPosition,
            .request_render = requestWorkbenchFrame,
            .title_actions_changed = struct {
                fn changed(context: *anyopaque) void {
                    const workbench: *TerminalWorkbench = @ptrCast(@alignCast(context));
                    workbench.sidebar_part.updateTitleArea();
                }
            }.changed,
            .focus_editor = outlineFocusEditor,
            .is_symbol_visible = outlineSymbolVisible,
        }, &self.outline_service);
        errdefer view.deinit();
        try view.registerList(&self.lists);
        try view.attachMarkerService(self.marker_service);
        view.setThemeColors(self.theme_palette);
        view.setBorderRendering(self.part.cell_borders);
        self.outline_view = view;
        return view;
    }

    pub fn requestFrame(self: *TerminalWorkbench) void {
        if (self.frame_scheduler) |scheduler| scheduler.request(scheduler.context);
    }

    pub fn resize(self: *TerminalWorkbench, cols: usize, rows: usize) !void {
        _ = self.cancelSashDrag();
        self.editor_drop_target.clearTabDrag();
        self.terminal_tabbed_view.tab_list.dragging_sash = false;
        self.terminal_tabbed_view.tab_list.dragging_pane_sash = null;
        self.terminal_tabbed_view.tab_list.dragged_instance = null;
        self.terminal_tabbed_view.tab_list.drag_target = null;
        const new_cols = @max(cols, 1);
        const new_rows = @max(rows, 1);
        if (new_cols == self.cols and new_rows == self.rows) return;
        self.window_events.fireWindowEvent(.resize);

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
    pub fn setCellBorders(self: *TerminalWorkbench, enabled: bool) void {
        if (self.outline_view) |view| view.setBorderRendering(enabled);
        if (self.part.cell_borders == enabled) return;
        self.part.setCellBorders(enabled);
        if (self.geometry().sidebarShown() or self.geometry().panelShown() or self.part.maximized_group != null) self.layoutAll();
    }

    pub fn setCellBorderCapabilities(self: *TerminalWorkbench, capabilities: ?ui.cell_border.Capabilities) void {
        self.part.cell_border_capabilities = capabilities orelse .{};
        self.setCellBorders(capabilities != null);
    }

    /// Hosts enable OSC 22 emission. Unlike borders and images the TUI does
    /// not probe: a pointer shape is out-of-band terminal state, so terminals
    /// without support ignore the sequence and nothing in the frame changes.
    pub fn setPointerShapes(self: *TerminalWorkbench, enabled: bool) void {
        self.pointer_shapes = enabled;
    }

    /// The shape the next frame requests; the renderer diffs it against the
    /// shape already written to the terminal.
    pub fn setPointer(self: *TerminalWorkbench, shape: ui.Pointer) void {
        self.pointer = shape;
    }

    pub fn pointerShape(self: *const TerminalWorkbench) ui.Pointer {
        return self.pointer;
    }
};

fn explorerPaneRenderBody(context: *anyopaque, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) !void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    const sidebar = self.sidebar orelse return;
    try sidebar.render(grid, rect, focused, .{
        .show_header = false,
        .cell_borders = self.part.cell_borders,
    });
}

fn explorerPaneBodyVisible(context: *anyopaque, visible: bool) void {
    if (!visible) return;
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    if (self.sidebar) |sidebar| sidebar.selectActiveFile() catch {};
}

fn explorerPaneHandleKey(context: *anyopaque, event: *ui.KeyEvent) !bool {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
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
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    const sidebar = self.sidebar orelse return false;
    return sidebar.handleMouse(event);
}

fn runPaneTitleAction(context: *anyopaque, id: []const u8) void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    self.runSidebarTitleAction(id, null);
}

fn explorerPaneTitleActions(_: *anyopaque) []const views_mod.TitleAction {
    return &.{};
}

fn outlinePaneRenderBody(context: *anyopaque, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) !void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    if (self.outline_view) |view| try view.render(grid, rect, focused);
}

fn outlinePaneHandleKey(context: *anyopaque, event: *ui.KeyEvent) !bool {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    if (self.outline_view) |view| return view.handleKey(event);
    return false;
}

fn outlinePaneHandleMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) !bool {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    if (self.outline_view) |view| return view.handleMouse(event, rect);
    return false;
}

fn outlinePaneTitleActions(context: *anyopaque) []const views_mod.TitleAction {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    if (self.outline_view) |view| return view.titleActions();
    return OutlinePane.empty_title_actions;
}

fn outlinePaneViewVisible(context: *anyopaque, visible: bool) void {
    if (!visible) return;
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    _ = self.ensureOutlineView() catch return;
}

fn outlinePaneBodyVisible(context: *anyopaque, visible: bool) void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    const view = if (visible) self.ensureOutlineView() catch return else self.outline_view orelse return;
    view.setBodyVisible(visible, self.editor_api) catch {};
}

fn outlineActiveEditor(context: *anyopaque) ?OutlineEditor {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return null;
    if (tab.isImage() or tab.isDiff() or tab.isMultiDiff() or tab.markdown_panel != null or tab.terminal_input != null) return null;
    return .{
        .context = @ptrCast(tab),
        .control = tab.editor,
        .resource = tab.editor.path,
        .language_id = tab.editor.languageId(),
    };
}

fn outlineActiveResource(context: *anyopaque) ?[]const u8 {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return null;
    return tab.editor.path;
}

fn outlineViewCurrentPosition(context: *anyopaque) ?Position {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return null;
    return tab.editor.modelSelection().getStartPosition();
}

fn requestWorkbenchFrame(context: *anyopaque) void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    self.requestFrame();
}

fn outlineFocusEditor(context: *anyopaque) void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    self.focusEditor();
    if (self.activeTab()) |tab| tab.focusEditor();
}

fn outlineSymbolVisible(context: *anyopaque, kind: u32) bool {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    return self.boolSetting(outline_contrib.showConfigForKind(kind), true);
}

fn breadcrumbFocusEditor(context: *anyopaque) void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    self.focusEditor();
    if (self.activeTab()) |tab| tab.focusEditor();
}

fn navigationActiveEditor(context: *anyopaque) ?*Editor {
    const host: *TerminalWorkbench = @ptrCast(@alignCast(context));
    const tab = host.activeTab() orelse return null;
    return if (tab.isDiff() or tab.isMultiDiff()) null else tab.editor;
}

fn hasActiveEditor(context: *anyopaque) bool {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    return self.activeTab() != null;
}

fn lookupCommandBinding(self: *TerminalWorkbench, arena: Allocator, id: []const u8) !?@import("../vs/base/common/keybindings.zig").ResolvedKeybinding {
    const global = try self.ensureGlobalService();
    return try global.service.lookupKeybinding(arena, id, false) orelse try (try self.ensureTabService()).service.lookupKeybinding(arena, id, false) orelse blk: {
        const tab = self.activeTab() orelse return null;
        if (tab.isDiff() or tab.isMultiDiff()) return null;
        break :blk try tab.editor.lookupShortcut(id) orelse return null;
    };
}

fn quickLookupKeycaps(context: *anyopaque, arena: Allocator, id: []const u8) anyerror![]const []const u8 {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    const binding = (try lookupCommandBinding(self, arena, id)) orelse return &.{};
    return @import("../vs/workbench/browser/quickaccess.zig").keycaps(arena, binding);
}

fn accessibilityKeybindingLabel(context: *anyopaque, arena: Allocator, id: []const u8) !?[]const u8 {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    const binding = (try lookupCommandBinding(self, arena, id)) orelse return null;
    return binding.getAriaLabel();
}

fn accessibilityVisibilityChanged(context: *anyopaque) void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    self.updateContextKeys();
}

fn quickGetExcludes(context: *anyopaque, allocator: Allocator) anyerror![]glob.ExcludeEntry {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    self.ensureConfiguration() catch {};
    const configuration = self.configuration orelse return allocator.alloc(glob.ExcludeEntry, 0);
    return search_types.getExcludes(
        allocator,
        configuration.getValue("files.exclude", .{}),
        configuration.getValue("search.exclude", .{}),
    );
}

fn quickGetFileSearchSettings(context: *anyopaque) search_types.FileSearchSettings {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
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
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    if (self.activeTab()) |tab| {
        tab.editor.setMessage("Quick open: {s}", .{message});
    }
}

fn quickCancelPopups(context: *anyopaque) void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    if (self.activeTab()) |tab| {
        tab.cancelEditorPopups();
    }
}

fn problemsWorkspaceRoot(context: *anyopaque) ?[]const u8 {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    return self.workspaceFolderPath();
}

fn problemsOpenEditor(context: *anyopaque, marker: *const markers_mod.Marker, preserve_focus: bool, pinned: bool) anyerror!void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
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
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    self.updateProblemsHighlight();
}

fn problemsFocusEditor(context: *anyopaque) void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    self.focusEditor();
    if (self.activeTab()) |tab| tab.focusEditor();
}

fn focusWindowEditor(context: *anyopaque) void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    self.focusEditor();
}

fn reportEditorMessage(context: *anyopaque, message: []const u8) bool {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return false;
    tab.editor.setMessage("{s}", .{message});
    return true;
}

fn statusFocusEditor(context: *anyopaque) void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    self.focusEditor();
}

fn executeStatusbarCommand(context: *anyopaque, command: statusbar_types.StatusbarCommand) anyerror!void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    if (statusbar_types.isTooltipCommand(command)) return;
    _ = try self.commands.platform.execute(command.id);
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
    .{ .id = "workbench.view.extensions", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyX) } },
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

fn executeTabCommand(context: *anyopaque, command_id: []const u8) anyerror!void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
    if (try self.runTabCommand(command_id)) |result| self.tab_command_result = result;
}

fn executeGlobalCommand(context: *anyopaque, command_id: []const u8) anyerror!void {
    const self: *TerminalWorkbench = @ptrCast(@alignCast(context));
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
