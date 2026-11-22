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
//! when a group empties, its sash resize, and tab drag/drop into a group,
//! onto a pane edge, or onto a tab strip with an insertion preview; the full
//! N-ary branch model is not ported yet.
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
//!
//! Async terminal adaptation: interactive read paths (`requestOpenPath`,
//! explorer expansion, image/Markdown previews and remote Markdown images) run
//! on the workbench's dedicated `std.Io.Threaded` via `Io.async`. No generic
//! Task/Promise type is introduced: each owner keeps an `Io.Future` plus a
//! completion flag, and `pollAsyncReads`/`pollFileWatcher`/`markdownPreviewTick`
//! apply results on the TUI thread. Watcher-triggered settings/keybindings/
//! theme reloads and clean-editor external changes use the same model:
//! `SettingsWatcher` reads sources off-thread, theme preparation returns a
//! detached `ColorThemeData`, and reload jobs resolve the tab by path when the
//! result lands. `openPath` stays synchronous for startup, session restore and
//! tests.

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
const file_icon = @import("./fileIcon.zig");
const Sidebar = @import("../contrib/files/browser/views/explorerView.zig").Sidebar;
const activity_bar_mod = @import("./parts/activitybar/activitybarPart.zig");
const ActivityBarPart = @import("./parts/activitybar/activitybarPart.zig").ActivityBarPart;
const sidebar_part_mod = @import("./parts/sidebar/sidebarPart.zig");
const SidebarPart = sidebar_part_mod.SidebarPart;
const layout_service_mod = @import("../services/layout/browser/layoutService.zig");
const LayoutModel = @import("./layout.zig").LayoutModel;
const statusbar_mod = @import("./parts/statusbar/statusbarPart.zig");
const statusbar_actions = @import("./parts/statusbar/statusbarActions.zig");
const statusbar_model_mod = @import("./parts/statusbar/statusbarModel.zig");
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
const workbench_configuration = @import("./workbenchConfiguration.zig");

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
const color_utils = @import("../../platform/theme/common/colorUtils.zig");
const syntax_theme_mod = @import("../../editor/standalone/browser/standaloneThemeService.zig");
const textmate_background_mod = @import("../services/textMate/browser/backgroundTokenization/threadedBackgroundTokenizerFactory.zig");
const TokenizationRegistry = @import("../../editor/common/tokenizationRegistry.zig").TokenizationRegistry;
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
const pane_composite_mod = @import("./parts/paneCompositePart.zig");

/// Upstream `Markers.MARKERS_CONTAINER_ID` and `TERMINAL_VIEW_ID`.
const PROBLEMS_CONTAINER_ID = markers_common.Markers.MARKERS_CONTAINER_ID;
const TERMINAL_CONTAINER_ID = "terminal";
const problems_view_mod = @import("../../../tui/problemsView.zig");
const ProblemsView = problems_view_mod.ProblemsView;
const panel_part_mod = @import("./parts/panel/panelPart.zig");
const PanelPart = panel_part_mod.PanelPart;
const views_mod = @import("../common/views.zig");
const view_descriptor_service_mod = @import("../services/views/browser/viewDescriptorService.zig");
const ViewDescriptorService = view_descriptor_service_mod.ViewDescriptorService;
const range_highlight_mod = @import("./codeeditor.zig");
const RangeHighlightDecorations = range_highlight_mod.RangeHighlightDecorations;

const search_view_mod = @import("../contrib/search/browser/searchViewTerminal.zig");
const SearchView = search_view_mod.SearchView;
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
const sticky_actions = @import("../../editor/contrib/stickyScroll/browser/stickyScrollActions.zig");
const strings = @import("../../base/common/strings.zig");
const topmost_line_monitor = @import("../contrib/markdown/browser/topmostLineMonitor.zig");
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
const git_mod = @import("../../../extensions/git/src/git.zig");
const git_service_mod = @import("../contrib/git/browser/gitService.zig");
const git_common_mod = @import("../contrib/git/common/gitService.zig");
const scm_service_mod = @import("../contrib/scm/common/scmService.zig");
const scm_common = @import("../contrib/scm/common/scm.zig");
const quick_diff_service_mod = @import("../contrib/scm/common/quickDiffService.zig");
const quick_diff_controller_mod = @import("../../../tui/quickDiffController.zig");
const repository_mod = @import("../../../extensions/git/src/repository.zig");
const scm_view_mod = @import("../contrib/scm/browser/scmViewPane.zig");
const scm_history_view_mod = @import("../contrib/scm/browser/scmHistoryViewPane.zig");
const scm_common_history = @import("../contrib/scm/common/history.zig");
const view_container_model_mod = @import("../services/views/common/viewContainerModel.zig");
const view_pane_container_mod = @import("./parts/views/viewPaneContainer.zig");
const text_diff_editor_mod = @import("./parts/editor/textDiffEditor.zig");
const storage_mod = @import("../../platform/storage/common/storage.zig");
const TerminalService = terminal_service_mod.TerminalService;

const search_command_ids = @import("../contrib/search/common/constants.zig").SearchCommandIds;

/// Side bar title toolbar actions of the Search view container, matching the
/// `MenuId.ViewTitle` actions upstream. The terminal workbench supplies only
/// the actions it can run; the Explorer's file actions are not ported as
/// commands, while the SCM view supplies refresh and list/tree itself.
const search_title_actions = [_]pane_composite_mod.TitleAction{
    .{ .id = search_command_ids.clear_search_results, .label = "Clear Search Results", .glyph = 'x' },
};
const search_title_secondary_actions = [_]pane_composite_mod.TitleAction{
    .{ .id = search_command_ids.toggle_query_details, .label = "Toggle Search Details", .glyph = 0x2026 },
};

pub const TabKeyResult = enum { unhandled, handled, quit };
pub const SplitDirection = grid_mod.Orientation;
pub const Focus = enum { editor, sidebar, statusbar, breadcrumbs, terminal, problems };

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
    panel_focus: context_key_mod.IContextKey,
    panel_visible: context_key_mod.IContextKey,
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

/// A tab drag can drop in the middle of a pane (move into that group), on an
/// edge (split that pane and move into the new group), or on a tab strip
/// (insert at the previewed tab position), mirroring VS Code's drop locations.
const DropZone = editor_drop_target.Zone;
const DropTarget = editor_drop_target.Target(*GroupPane);
/// Upstream `MultiEditorTabsControl.dropTarget`: the tab strip under a live
/// drag and the ordered insertion index. Mutually exclusive with
/// `drag_target`, the editor-content split/placement target.
const TabDrop = struct { pane: *GroupPane, index: usize };
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
const text_editor_selection_mod = @import("./parts/editor/textEditor.zig");
const editor_widget = @import("../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");

/// Result of reading and decoding a file on the async Io. The text is owned by
/// the job until `Editor.create*FromLoadedText` has copied what the model
/// needs.
const OpenOutcome = union(enum) {
    text: editor_widget.LoadedText,
    err: anyerror,
};

/// One interactive text open on the async Io. No generic Task/Promise layer:
/// the job owns the raw `Io.Future`, the completion flag and the request data.
const OpenJob = struct {
    owner: *Workbench,
    future: Io.Future(OpenOutcome),
    done: std.atomic.Value(bool) = .init(false),
    path: []u8,
    generation: u64,
    options: Workbench.OpenOptions,
};

const ThemeLoadOutcome = union(enum) {
    theme: *@import("../services/themes/common/colorThemeData.zig").ColorThemeData,
    err: anyerror,
};

/// One worker-thread color-theme load. The prepared theme is installed on the
/// TUI thread by `pollThemeJob`.
const ThemeLoadJob = struct {
    allocator: Allocator,
    io: Io,
    service: *theme_service_mod.ThemeService,
    future: Io.Future(ThemeLoadOutcome),
    done: std.atomic.Value(bool) = .init(false),
    request: theme_service_mod.ThemeService.PrepareRequest,
};

fn runThemeLoadJob(job: *ThemeLoadJob) ThemeLoadOutcome {
    defer job.done.store(true, .release);
    const theme = theme_service_mod.ThemeService.prepareTheme(
        job.allocator,
        job.service.colors,
        &job.request,
        job.io,
    ) catch |err| return .{ .err = err };
    return .{ .theme = theme };
}

const KeybindingsOutcome = union(enum) {
    bindings: *user_keybindings_mod.UserKeybindings,
    err: anyerror,
};

const KeybindingsJob = struct {
    allocator: Allocator,
    io: Io,
    future: Io.Future(KeybindingsOutcome),
    done: std.atomic.Value(bool) = .init(false),
    paths: [][]u8,

    fn deinit(self: *KeybindingsJob, allocator: Allocator) void {
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
        allocator.destroy(self);
    }
};

fn runKeybindingsJob(job: *KeybindingsJob) KeybindingsOutcome {
    defer job.done.store(true, .release);
    var path_views = std.array_list.Managed([]const u8).init(job.allocator);
    defer path_views.deinit();
    for (job.paths) |path| path_views.append(path) catch return .{ .err = error.OutOfMemory };
    const bindings = user_keybindings_mod.UserKeybindings.load(job.allocator, job.io, path_views.items) catch |err| {
        return .{ .err = err };
    };
    return .{ .bindings = bindings };
}

const ReloadOutcome = union(enum) {
    content: editor_widget.ReloadedContent,
    err: anyerror,
};

/// One external-change reload on the async Io. The job stores only the path;
/// the tab is resolved again when the result lands, so closing a tab while the
/// read is in flight cannot leave a dangling pointer.
const ReloadJob = struct {
    allocator: Allocator,
    io: Io,
    future: Io.Future(ReloadOutcome),
    done: std.atomic.Value(bool) = .init(false),
    path: []u8,
};

fn runReloadJob(job: *ReloadJob) ReloadOutcome {
    defer job.done.store(true, .release);
    const content = editor_widget.Editor.readReloadedContent(job.allocator, job.io, job.path) catch |err| {
        return .{ .err = err };
    };
    return .{ .content = content };
}

pub const Workbench = struct {
    allocator: Allocator,
    io: Io,
    /// Io used to run interactive file/dir/network work off the TUI thread.
    /// It is a separate instance from `io` with `async_limit = .unlimited` so
    /// `Io.async` never falls back to running a blocking read inline on the
    /// TUI thread just because the default pool is busy. `io` remains the
    /// terminal/synchronous-startup instance.
    async_io_state: Io.Threaded,
    async_io: Io,
    /// The single interactive open currently in flight. A newer request
    /// supersedes it; the generation is checked again when the result lands.
    pending_open: ?*OpenJob = null,
    open_generation: u64 = 0,
    reload_jobs: std.array_list.Managed(*ReloadJob),
    theme_job: ?*ThemeLoadJob = null,
    keybindings_job: ?*KeybindingsJob = null,
    keybindings_reload_pending: bool = false,
    theme_candidates: [3]?[]u8 = .{ null, null, null },
    theme_candidate_index: usize = 0,
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
    drag_tab_drop: ?TabDrop = null,
    sidebar: ?*Sidebar = null,
    search_view: ?*SearchView = null,
    search_service: ?*SearchService = null,
    layout_model: LayoutModel,
    activity_bar_part: ActivityBarPart,
    sidebar_part: SidebarPart,
    panel_part: PanelPart,
    view_containers_registry: views_mod.ViewContainersRegistry,
    view_descriptor_service: ViewDescriptorService,
    statusbar: StatusbarService,
    images: ui.image.Runtime,
    /// Desired OSC 22 mouse pointer shape for the next frame. Only the
    /// composited renderer writes it; pane surfaces resolve shapes but never
    /// emit them.
    pointer: ui.Pointer = .default,
    pointer_state: ui.pointer.State = .{},
    pointer_shapes: bool = false,
    media_status: ?*MediaPreviewStatus = null,
    /// Set when a file watcher change was applied so the TUI repaints even if
    /// the change produced no other input.
    files_changed: bool = false,
    activity_service: ActivityService,
    editor_status: ?*EditorStatus = null,
    status_hint_accessor: ?EntryAccessor = null,
    /// Stable storage for the transient "Opening ..." status hint; the
    /// status-bar entry keeps the slice.
    status_hint_buf: [256]u8 = undefined,
    /// Branch-aware placeholder for the Source Control commit input.
    scm_placeholder_buf: [160]u8 = undefined,
    scm_hover_surface: ?ui.Surface = null,
    markers_status: ?*MarkersStatusBar = null,
    problems_view: ?*ProblemsView = null,
    marker_listener: ?@import("../../base/common/event.zig").Emitter(MarkerChangeEvent).ListenerId = null,
    range_highlights: ?*RangeHighlightDecorations = null,
    search_badge_buf: [32]u8 = undefined,
    search_badge_count: usize = 0,
    workspace: *WorkspaceContextService,
    configuration: ?*ConfigurationService,
    settings_watcher: ?*SettingsWatcher = null,
    /// Workspace file watcher service. Kept separate from the settings watcher
    /// so a workspace change never triggers a settings reload. The recursive
    /// scan runs on the service's worker thread.
    file_watcher_service: ?*FileWatcherService = null,
    /// Port of the `workspaceWatcher.ts` contribution. Instantiated by the
    /// upstream `AfterRestored` phase, after the first frame.
    workspace_watcher: ?*WorkspaceWatcher = null,
    contributions: contributions_mod.WorkbenchContributions,
    after_restored_ran: bool = false,
    user_settings_paths: []const []const u8,
    /// User keybinding files (VS Code profile then TUI override). Watched by
    /// the settings watcher; reloaded with the rest of the configuration.
    keybindings_paths: []const []const u8,
    history: HistoryService,
    /// True while restoring a navigation entry; suppresses recording the
    /// restore as another navigation.
    history_navigating: bool = false,
    history_state_path: ?[]u8 = null,
    history_tab: ?*Tab = null,
    history_selection_listener: ?Tab.SelectionListener = null,
    history_content_listener: ?editor_widget.ChangeListener = null,
    in_closed_batch: bool = false,
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
    /// Process-wide async TextMate tokenizer. Created lazily by
    /// `enableAsyncTokenization`, so tests keep the synchronous fallback.
    textmate_background: ?*textmate_background_mod.Factory = null,
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
    /// Persistent breadcrumb controls for inactive groups, keyed by group id.
    /// Rendering an inactive group must not rebuild its outline every frame.
    breadcrumbs_inactive: std.AutoHashMapUnmanaged(u32, *InactiveBreadcrumb) = .empty,
    home_path: ?[]u8 = null,
    breadcrumbs_arena: std.heap.ArenaAllocator,
    navigation_arena: std.heap.ArenaAllocator,
    pending_references: ?*ReferencesModel = null,
    pending_symbols: ?[]goto_symbol_quick_access.Entry = null,
    symbol_action_contexts: [go_to_commands.actions.len]SymbolActionContext = undefined,
    breadcrumbs_dirty: bool = false,
    tab_menu_pane: ?*GroupPane = null,
    tab_menu_tab: ?*Tab = null,
    tab_overflow_tabs: ?[]*Tab = null,
    hovered_tab: ?*Tab = null,
    hovered_pane: ?*GroupPane = null,
    hovered_title_action_pane: ?*GroupPane = null,
    last_tab_click: ?TabClick = null,
    expanded_pane: ?*GroupPane = null,
    /// Pointer capture for the side-bar divider drag.
    sidebar_resize_active: bool = false,
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
    git: ?*git_mod.Git = null,
    git_delegate: ?*git_common_mod.IGitExtensionDelegate = null,
    git_service: ?*git_service_mod.GitService = null,
    scm_service: ?*scm_service_mod.SCMService = null,
    quick_diff_storage: ?*storage_mod.InMemoryStorageService = null,
    quick_diff_service: ?*quick_diff_service_mod.QuickDiffService = null,
    quick_diff_controller: ?*quick_diff_controller_mod.Controller = null,
    scm_view: ?*scm_view_mod.SCMViewPane = null,
    scm_history_view: ?*scm_history_view_mod.SCMHistoryViewPane = null,
    scm_view_model: ?*view_container_model_mod.ViewContainerModel = null,
    scm_container: ?*view_pane_container_mod.ViewPaneContainer = null,
    scm_panes: ?[]view_pane_container_mod.Pane = null,
    repository: ?*repository_mod.Repository = null,
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
        self.async_io_state = Io.Threaded.init(allocator, .{
            .async_limit = .unlimited,
            .environ = asyncEnviron(),
        });
        errdefer self.async_io_state.deinit();
        self.async_io = self.async_io_state.io();
        self.pending_open = null;
        self.open_generation = 0;
        self.reload_jobs = std.array_list.Managed(*ReloadJob).init(allocator);
        self.theme_job = null;
        self.theme_candidates = .{ null, null, null };
        self.theme_candidate_index = 0;
        self.keybindings_job = null;
        self.keybindings_reload_pending = false;
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
        self.textmate_background = null;
        self.theme_scheme_host = .{};
        self.theme_palette = null;
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.terminal_service = null;
        self.terminal_input = .{};
        self.suppress_global_command = false;
        self.git = null;
        self.git_delegate = null;
        self.git_service = null;
        self.scm_service = null;
        self.scm_interface = null;
        self.quick_diff_storage = null;
        self.quick_diff_service = null;
        self.quick_diff_controller = null;
        self.scm_view = null;
        self.scm_history_view = null;
        self.scm_view_model = null;
        self.scm_container = null;
        self.scm_panes = null;
        self.scm_hover_surface = null;
        self.repository = null;
        self.git_root = null;
        self.git_status_accessor = null;
        self.git_badge_count = 0;
        self.next_git_refresh = 0;
        self.git_status_dirty = true;
        self.quit_requested = false;
        self.dialog = null;
        self.pending_dialog = null;
        self.images = ui.image.Runtime.init(allocator);
        self.pointer = .default;
        self.pointer_state = .{};
        self.pointer_shapes = false;
        self.media_status = null;
        self.files_changed = false;
        self.pending_tab_drag = null;
        self.drag_tab = null;
        self.drag_source_pane = null;
        self.drag_target = null;
        self.drag_tab_drop = null;
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
        self.breadcrumbs_inactive = .empty;
        self.home_path = readHomePath(allocator);
        self.breadcrumbs_registration = null;
        self.breadcrumbs_group = null;
        self.breadcrumbs_pane = null;
        self.breadcrumbs_input = null;
        self.breadcrumbs_dirty = false;
        self.tab_menu_pane = null;
        self.tab_menu_tab = null;
        self.tab_overflow_tabs = null;
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
        self.file_watcher_service = null;
        self.workspace_watcher = null;
        self.contributions = contributions_mod.WorkbenchContributions.init(allocator);
        self.after_restored_ran = false;
        errdefer self.contributions.deinit();
        try self.contributions.register(.after_restored, self, initAfterRestoredWorkspaceWatcher);
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
        self.async_io_state = Io.Threaded.init(allocator, .{
            .async_limit = .unlimited,
            .environ = asyncEnviron(),
        });
        errdefer self.async_io_state.deinit();
        self.async_io = self.async_io_state.io();
        self.pending_open = null;
        self.open_generation = 0;
        self.reload_jobs = std.array_list.Managed(*ReloadJob).init(allocator);
        self.theme_job = null;
        self.theme_candidates = .{ null, null, null };
        self.theme_candidate_index = 0;
        self.keybindings_job = null;
        self.keybindings_reload_pending = false;
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
        self.textmate_background = null;
        self.theme_scheme_host = .{};
        self.theme_palette = null;
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.terminal_service = null;
        self.terminal_input = .{};
        self.suppress_global_command = false;
        self.git = null;
        self.git_delegate = null;
        self.git_service = null;
        self.scm_service = null;
        self.scm_interface = null;
        self.quick_diff_storage = null;
        self.quick_diff_service = null;
        self.quick_diff_controller = null;
        self.scm_view = null;
        self.scm_history_view = null;
        self.scm_view_model = null;
        self.scm_container = null;
        self.scm_panes = null;
        self.scm_hover_surface = null;
        self.repository = null;
        self.git_root = null;
        self.git_status_accessor = null;
        self.git_badge_count = 0;
        self.next_git_refresh = 0;
        self.git_status_dirty = true;
        self.quit_requested = false;
        self.dialog = null;
        self.pending_dialog = null;
        self.images = ui.image.Runtime.init(allocator);
        self.pointer = .default;
        self.pointer_state = .{};
        self.pointer_shapes = false;
        self.media_status = null;
        self.files_changed = false;
        self.pending_tab_drag = null;
        self.drag_tab = null;
        self.drag_source_pane = null;
        self.drag_target = null;
        self.drag_tab_drop = null;
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
        self.breadcrumbs_inactive = .empty;
        self.home_path = readHomePath(allocator);
        self.breadcrumbs_registration = null;
        self.breadcrumbs_group = null;
        self.breadcrumbs_pane = null;
        self.breadcrumbs_input = null;
        self.breadcrumbs_dirty = false;
        self.tab_menu_pane = null;
        self.tab_menu_tab = null;
        self.tab_overflow_tabs = null;
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
        self.file_watcher_service = null;
        self.workspace_watcher = null;
        self.contributions = contributions_mod.WorkbenchContributions.init(allocator);
        self.after_restored_ran = false;
        errdefer self.contributions.deinit();
        try self.contributions.register(.after_restored, self, initAfterRestoredWorkspaceWatcher);
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
            if (std.mem.eql(u8, input.type_id, ImagePreviewEditorInput.ID)) {
                const image_input: *ImagePreviewEditorInput = @ptrCast(@alignCast(input.impl.?));
                const tab = try Tab.initImageFromInput(
                    allocator,
                    self.io,
                    image_input,
                    self.cols,
                    @max(self.rows -| 2, 1),
                    &self.images,
                    null,
                );
                try tab.view.setStatusBarVisible(false);
                try pane.addTab(tab);
                try self.history.add(image_input.path);
                continue;
            }
            if (!std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID)) continue;
            const file_input: *FileEditorInput = @ptrCast(@alignCast(input.impl.?));
            const tab = try Tab.initFromInput(allocator, file_input);
            tab.setImageRuntime(&self.images);
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
        self.async_io_state = Io.Threaded.init(allocator, .{
            .async_limit = .unlimited,
            .environ = asyncEnviron(),
        });
        errdefer self.async_io_state.deinit();
        self.async_io = self.async_io_state.io();
        self.pending_open = null;
        self.open_generation = 0;
        self.reload_jobs = std.array_list.Managed(*ReloadJob).init(allocator);
        self.theme_job = null;
        self.theme_candidates = .{ null, null, null };
        self.theme_candidate_index = 0;
        self.keybindings_job = null;
        self.keybindings_reload_pending = false;
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
        self.textmate_background = null;
        self.theme_scheme_host = .{};
        self.theme_palette = null;
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.terminal_service = null;
        self.terminal_input = .{};
        self.suppress_global_command = false;
        self.git = null;
        self.git_delegate = null;
        self.git_service = null;
        self.scm_service = null;
        self.scm_interface = null;
        self.quick_diff_storage = null;
        self.quick_diff_service = null;
        self.quick_diff_controller = null;
        self.scm_view = null;
        self.scm_history_view = null;
        self.scm_view_model = null;
        self.scm_container = null;
        self.scm_panes = null;
        self.scm_hover_surface = null;
        self.repository = null;
        self.git_root = null;
        self.git_status_accessor = null;
        self.git_badge_count = 0;
        self.next_git_refresh = 0;
        self.git_status_dirty = true;
        self.quit_requested = false;
        self.dialog = null;
        self.pending_dialog = null;
        self.images = ui.image.Runtime.init(allocator);
        self.pointer = .default;
        self.pointer_state = .{};
        self.pointer_shapes = false;
        self.media_status = null;
        self.files_changed = false;
        self.pending_tab_drag = null;
        self.drag_tab = null;
        self.drag_source_pane = null;
        self.drag_target = null;
        self.drag_tab_drop = null;
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
        self.breadcrumbs_inactive = .empty;
        self.home_path = readHomePath(allocator);
        self.breadcrumbs_registration = null;
        self.breadcrumbs_group = null;
        self.breadcrumbs_pane = null;
        self.breadcrumbs_input = null;
        self.breadcrumbs_dirty = false;
        self.tab_menu_pane = null;
        self.tab_menu_tab = null;
        self.tab_overflow_tabs = null;
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
        self.file_watcher_service = null;
        self.workspace_watcher = null;
        self.contributions = contributions_mod.WorkbenchContributions.init(allocator);
        self.after_restored_ran = false;
        errdefer self.contributions.deinit();
        try self.contributions.register(.after_restored, self, initAfterRestoredWorkspaceWatcher);
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
                if (std.mem.eql(u8, input.type_id, ImagePreviewEditorInput.ID)) {
                    const image_input: *ImagePreviewEditorInput = @ptrCast(@alignCast(input.impl.?));
                    const tab = try Tab.initImageFromInput(
                        allocator,
                        self.io,
                        image_input,
                        self.cols,
                        @max(self.rows -| 2, 1),
                        &self.images,
                        null,
                    );
                    try tab.view.setStatusBarVisible(false);
                    try pane.addTab(tab);
                    try self.history.add(image_input.path);
                    continue;
                }
                if (!std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID)) continue;
                const file_input: *FileEditorInput = @ptrCast(@alignCast(input.impl.?));
                const tab = try Tab.initFromInput(allocator, file_input);
                tab.setImageRuntime(&self.images);
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
        self.marker_listener = null;
        self.markers_status = null;
        self.range_highlights = null;
        self.layout_model = LayoutModel.init(self.allocator);
        errdefer self.layout_model.deinit();
        self.activity_bar_part = ActivityBarPart.init(self.allocator);
        errdefer self.activity_bar_part.deinit();
        self.sidebar_part = SidebarPart.init(self.allocator);
        errdefer self.sidebar_part.deinit();
        self.sidebar_part.attachActivityBar(&self.activity_bar_part);
        self.panel_part = PanelPart.init(self.allocator);
        errdefer self.panel_part.deinit();
        self.view_containers_registry = views_mod.ViewContainersRegistry.init(self.allocator);
        errdefer self.view_containers_registry.deinit();
        self.view_descriptor_service = ViewDescriptorService.init(self.allocator, &self.view_containers_registry);
        errdefer self.view_descriptor_service.deinit();
        try self.view_descriptor_service.attach();
        self.statusbar = try StatusbarService.init(self.allocator);
        errdefer self.statusbar.deinit();
        self.activity_service = ActivityService.init(self.allocator);
        errdefer self.activity_service.deinit();

        try self.setSidebarWidth(28);
        try self.layout_model.setVisible(.sidebar, false);
        try self.layout_model.setVisible(.activitybar, true);
        try self.layout_model.setVisible(.statusbar, true);

        for (activity_bar_mod.default_activities) |activity| {
            try self.activity_bar_part.addActivity(activity);
        }
        try self.activity_bar_part.setVisible(true);

        try self.registerViewContainers();
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
            .glyph = 'E',
            .order = 0,
        }, .sidebar, .{ .is_default = true });
        _ = try registry.register(.{
            .id = "search",
            .title = "Search",
            .glyph = 'F',
            .order = 1,
        }, .sidebar, .{});
        _ = try registry.register(.{
            .id = "scm",
            .title = "Source Control",
            .glyph = 'G',
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
        self.panel_part.deinit();
        self.sidebar_part.deinit();
        self.view_descriptor_service.deinit();
        self.view_containers_registry.deinit();
        self.activity_bar_part.deinit();
        self.layout_model.deinit();
    }

    fn initQuickAccess(self: *Workbench) !void {
        self.history_state_path = null;
        self.history_navigating = false;
        self.history_tab = null;
        self.history_selection_listener = null;
        self.history_content_listener = null;
        self.in_closed_batch = false;
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
                .get_excludes = quickGetExcludes,
                .get_file_search_settings = quickGetFileSearchSettings,
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
        self.media_status = try MediaPreviewStatus.init(self.allocator, &self.statusbar);
        errdefer {
            if (self.media_status) |status| status.deinit();
            self.media_status = null;
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
            .{ .id = "workbench.action.reopenClosedEditor", .label = "Reopen Closed Editor", .category = "View", .context = self, .run = commandReopenClosedEditor },
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
            .{ .id = "workbench.action.togglePanel", .label = "View: Toggle Panel Visibility", .category = "View", .context = self, .run = commandTogglePanel },
            .{ .id = "workbench.action.focusPanel", .label = "View: Focus Panel", .category = "View", .context = self, .run = commandFocusPanel },
            .{ .id = "workbench.action.previousPanelView", .label = "View: Previous Panel View", .category = "View", .context = self, .run = commandPreviousPanelView },
            .{ .id = "workbench.action.nextPanelView", .label = "View: Next Panel View", .category = "View", .context = self, .run = commandNextPanelView },
            .{ .id = "git.refresh", .label = "Refresh", .category = "Source Control", .context = self, .run = commandGitRefresh },
            .{ .id = "git.commit", .label = "Commit", .category = "Source Control", .context = self, .run = commandGitCommit },
            .{ .id = "workbench.scm.action.graph.refresh", .label = "Source Control Graph: Refresh", .category = "Source Control", .context = self, .run = commandScmHistoryRefresh },
            .{ .id = "workbench.scm.action.graph.pickHistoryItemRefs", .label = "Source Control Graph: Select History Item References", .category = "Source Control", .context = self, .run = commandScmHistoryPickRefs },
            .{ .id = "workbench.scm.action.graph.revealCurrentHistoryItem", .label = "Source Control Graph: Go to Current History Item", .category = "Source Control", .context = self, .run = commandScmHistoryReveal },
            .{ .id = "workbench.scm.action.graph.setListViewMode", .label = "Source Control Graph: View as List", .category = "Source Control", .context = self, .run = commandScmHistoryListMode },
            .{ .id = "workbench.scm.action.graph.setTreeViewMode", .label = "Source Control Graph: View as Tree", .category = "Source Control", .context = self, .run = commandScmHistoryTreeMode },
            .{ .id = scm_view_mod.SET_LIST_VIEW_MODE_ACTION_ID, .label = "View as List", .category = "Source Control", .context = self, .run = commandScmListMode },
            .{ .id = scm_view_mod.SET_TREE_VIEW_MODE_ACTION_ID, .label = "View as Tree", .category = "Source Control", .context = self, .run = commandScmTreeMode },
            .{ .id = scm_view_mod.SET_SORT_BY_NAME_ACTION_ID, .label = "Sort Changes by Name", .category = "Source Control", .context = self, .run = commandScmSortByName },
            .{ .id = scm_view_mod.SET_SORT_BY_PATH_ACTION_ID, .label = "Sort Changes by Path", .category = "Source Control", .context = self, .run = commandScmSortByPath },
            .{ .id = scm_view_mod.SET_SORT_BY_STATUS_ACTION_ID, .label = "Sort Changes by Status", .category = "Source Control", .context = self, .run = commandScmSortByStatus },
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
            .{ .id = media_actions.zoom_in_id, .label = media_actions.zoom_in_title, .category = media_actions.category, .requires_editor = true, .context = self, .run = commandImageZoomIn },
            .{ .id = media_actions.zoom_out_id, .label = media_actions.zoom_out_title, .category = media_actions.category, .requires_editor = true, .context = self, .run = commandImageZoomOut },
            .{ .id = media_actions.select_zoom_level_id, .label = media_actions.select_zoom_level_title, .category = media_actions.category, .requires_editor = true, .context = self, .run = commandImageSelectZoomLevel },
            .{ .id = media_actions.open_in_text_id, .label = media_actions.open_in_text_title, .category = media_actions.category, .requires_editor = true, .context = self, .run = commandImageOpenInTextEditor },
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
            .{ .id = sticky_actions.toggle_sticky_scroll.id, .label = sticky_actions.toggle_sticky_scroll.label, .category = "View", .context = self, .requires_editor = true, .run = commandToggleStickyScroll },
            .{ .id = sticky_actions.focus_sticky_scroll.id, .label = sticky_actions.focus_sticky_scroll.label, .category = "View", .context = self, .requires_editor = true, .run = commandFocusStickyScroll },
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
        const was_open = self.quick_access.isOpen();
        const handled = try self.quick_access.handleKey(event);
        // A keyboard-opened picker covers whatever the pointer was over; reset
        // until the next mouse move resolves the new target.
        if (handled and !was_open and self.quick_access.isOpen()) self.pointer = .default;
        return handled;
    }

    pub fn handleQuickAccessMouse(self: *Workbench, event: *ui.MouseEvent) bool {
        const handled = self.quick_access.handleMouse(event);
        if (handled) self.pointer = self.quick_access.pointerAt(event.x, event.y);
        return handled;
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
        self.pointer = dialog.pointerAt(event.x, event.y);
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

    /// Enables the threaded TextMate background tokenizer. The TUI calls
    /// this after construction; tests leave it off so they keep the
    /// synchronous default background tokenizer.
    pub fn enableAsyncTokenization(self: *Workbench) void {
        if (self.textmate_background != null) return;
        const factory = textmate_background_mod.Factory.init(self.allocator) catch return;
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
        self.cancelAsyncJobs();
        if (self.textmate_background) |factory| {
            TokenizationRegistry.instance.setBackgroundTokenizerFactory(null);
            factory.shutdown();
        }
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
        self.disposeAllInactiveBreadcrumbs();
        if (self.tab_overflow_tabs) |tabs| {
            self.allocator.free(tabs);
            self.tab_overflow_tabs = null;
        }
        if (self.home_path) |home| {
            self.allocator.free(home);
            self.home_path = null;
        }
        self.breadcrumbs_arena.deinit();
        self.navigation_arena.deinit();
        self.breadcrumbs_service.deinit();
        self.outline_service.deinit();
        if (self.media_status) |status| {
            status.deinit();
            self.media_status = null;
        }
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
        self.saveHistoryState() catch {};
        if (self.history_tab) |tab| {
            if (self.history_selection_listener) |listener| tab.removeSelectionListener(listener);
            if (self.history_content_listener) |listener| tab.editor.removeWorkingCopyContentListener(listener);
            self.history_tab = null;
        }
        if (self.history_state_path) |path| self.allocator.free(path);
        self.history.deinit();
        // Dispose the service (and unregister editor listeners) before tab
        // inputs/emitters are destroyed.
        self.service.deinit();
        if (self.scm_hover_surface) |*surface| {
            surface.deinit();
            self.scm_hover_surface = null;
        }
        self.deinitGit();
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
        if (self.textmate_background) |factory| {
            factory.deinit();
            self.textmate_background = null;
        }
        self.images.deinit();
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
        self.async_io_state.deinit();
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

    /// The bottom panel is visible with an active container. `hideIfEmpty`
    /// containers hide their title (not the panel) while they are empty; the
    /// panel itself stays open until the workbench closes it.
    pub fn panelShown(self: *const Workbench) bool {
        return self.panel_part.isVisible() and self.panel_part.pane.active_id != null;
    }

    pub fn activePanelId(self: *const Workbench) []const u8 {
        return self.panel_part.pane.active_id orelse "";
    }

    /// The Terminal container is active and has at least one instance.
    pub fn terminalVisible(self: *const Workbench) bool {
        if (!self.panelShown()) return false;
        if (!std.mem.eql(u8, self.activePanelId(), TERMINAL_CONTAINER_ID)) return false;
        return self.terminal_service != null and self.terminal_service.?.count() > 0;
    }

    fn panelHeight(self: *const Workbench) usize {
        if (!self.panelShown()) return 0;
        const available = self.workbenchRows();
        const wanted = if (self.panel_part.getSize() == 0) 10 else self.panel_part.getSize();
        const max_height = @max(@min(available / 2, available -| 1), 1);
        return @min(@max(wanted, 2), max_height);
    }

    fn editorRows(self: *const Workbench) usize {
        return @max(self.workbenchRows() -| self.panelHeight(), 1);
    }

    pub fn panelRect(self: *const Workbench) ui.Rect {
        if (!self.panelShown()) return .{};
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

    /// Panel content below the one-row title (composite bar).
    pub fn panelContentRect(self: *const Workbench) ui.Rect {
        if (!self.panelShown()) return .{};
        return panel_part_mod.contentRect(self.panelRect());
    }

    fn editorAreaX(self: *const Workbench) usize {
        // The activity bar stays when the side bar is hidden, like upstream.
        var x = self.activityBarWidth();
        if (self.sidebarShown()) x += self.sidebarWidth() + 1;
        return x;
    }

    fn editorAreaWidth(self: *const Workbench) usize {
        return self.cols -| self.editorAreaX();
    }

    /// Editor content height: the rows above the workbench status bar minus the
    /// group chrome (tab strip plus the optional breadcrumb row).
    fn editorContentHeight(self: *Workbench) usize {
        return @max(self.editorRows() -| self.chromeHeight(), 1);
    }

    fn chromeHeight(self: *Workbench) usize {
        const tabs: usize = if (self.editorShowTabs() == .none) 0 else editor_group_view.title_height;
        return tabs + (if (self.breadcrumbs_settings.enabled) editor_group_view.breadcrumbs_height else 0);
    }

    fn breadcrumbsEnabled(self: *const Workbench) bool {
        return self.breadcrumbs_settings.enabled;
    }

    fn sidebarWidth(self: *const Workbench) usize {
        const max_width = @max(self.cols / 2, 10);
        return @min(self.layout_model.size(.sidebar), @max(max_width, 1));
    }

    fn activityBarWidth(self: *const Workbench) usize {
        // The activity bar takes no cells when it is hidden or when it moved
        // into the side bar composite bar (top/bottom positions). Without a
        // side bar model there is no side bar area for the rail either; the
        // terminal app always initializes the side bar.
        if (!self.activity_bar_part.visible) return 0;
        if (self.sidebar == null) return 0;
        return self.activity_bar_part.width();
    }

    fn sidebarShown(self: *const Workbench) bool {
        return self.layout_model.isVisible(.sidebar) and self.sidebar != null and
            self.activityBarWidth() + self.sidebarWidth() + 8 < self.cols;
    }

    fn setSidebarVisible(self: *Workbench, visible: bool) !void {
        try self.layout_model.setVisible(.sidebar, visible);
        try self.sidebar_part.setVisible(visible);
        if (visible) try self.syncActivityBarVisibility();
    }

    fn setSidebarWidth(self: *Workbench, width: usize) !void {
        try self.layout_model.setSize(.sidebar, width);
        try self.sidebar_part.setWidth(width);
    }

    /// Port of the composite action collection: the active side bar view
    /// container supplies the title toolbar actions.
    fn updateSidebarTitleActions(self: *Workbench) void {
        const container = self.sidebar_part.pane.active_id orelse "";
        if (std.mem.eql(u8, container, "search")) {
            self.sidebar_part.pane.setTitleActions(&search_title_actions, &search_title_secondary_actions) catch {};
        } else if (std.mem.eql(u8, container, "scm")) {
            const merged = if (self.scm_container) |value|
                value.mergedTitleActions(self.allocator) catch null
            else
                null;
            self.sidebar_part.pane.setTitleActions(merged orelse &.{}, &.{}) catch {};
        } else {
            self.sidebar_part.pane.setTitleActions(&.{}, &.{}) catch {};
        }
    }

    fn runSidebarTitleAction(self: *Workbench, id: []const u8) void {
        self.commands.execute(id) catch {};
    }

    /// Badges for the side bar composite bar (activity bar top/bottom), built
    /// from the same activity service the rail uses.
    fn sidebarBadges(
        self: *Workbench,
        texts: *[8][24]u8,
        badges: *[8]pane_composite_mod.Badge,
    ) []const pane_composite_mod.Badge {
        var count: usize = 0;
        for (self.activity_bar_part.activities.items) |activity| {
            if (count >= badges.len) break;
            const description = self.activity_service.getContainerBadgeDescription(activity.id) orelse continue;
            if (description.len == 0) continue;
            const len = @min(description.len, texts[count].len);
            @memcpy(texts[count][0..len], description[0..len]);
            badges[count] = .{ .id = activity.id, .text = texts[count][0..len] };
            count += 1;
        }
        return badges[0..count];
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
        if (self.configuration) |configuration| {
            configuration.deinit();
            self.configuration = null;
        }
        // Stop the quick-open listing while the old workspace snapshot is
        // still alive; the worker owns copies, but this keeps the ordering
        // explicit and drops picker items that borrow old paths.
        self.quick_access.endFileSession();
        self.workspace.deinit();
        self.workspace = replacement;
        replacement_owned = true;
        try self.ensureConfiguration();
        self.breadcrumbs_settings = BreadcrumbsSettings.load(self.configuration);
        self.disposeBreadcrumbs();
        self.layoutAll();
        try self.quick_access.setWorkspace(self.workspace);
        if (self.after_restored_ran and self.workspace.getWorkspace().folders.items.len > 0) {
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
            if (self.workspace_watcher) |watcher| {
                watcher.deinit();
                self.workspace_watcher = null;
            }
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
            if (self.after_restored_ran and self.workspace.getWorkspace().folders.items.len > 0) {
                self.ensureWorkspaceWatcher() catch |err| {
                    std.log.scoped(.file_watcher).err("failed to restart workspace watcher: {s}", .{@errorName(err)});
                };
            }
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
                .defaults_json = &.{
                    search_configuration.defaults_json,
                    terminal_configuration.defaults_json,
                    theme_configuration_mod.defaults_json,
                    workbench_configuration.defaults_json,
                },
            },
        );
        self.settings_watcher = SettingsWatcher.init(self.allocator, self.io, self.configuration.?) catch null;
        if (self.settings_watcher) |watcher| {
            watcher.setOnReload(.{ .context = self, .callback = onSettingsReloaded });
            watcher.setAsyncIo(self.async_io);
            watcher.setExtraPaths(self.keybindings_paths) catch {};
        }
        self.breadcrumbs_settings = BreadcrumbsSettings.load(self.configuration);
        self.applyLayoutSettings();
    }

    fn onSettingsReloaded(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.applyLayoutSettings();
        self.applyConfiguredLanguageAssociationsToAllEditors();
        self.applyEditorSettingsToAllTabs();
        self.requestKeybindingsReload();
        self.applyThemeSettingsAsync();
        self.applyBreadcrumbsSettings();
        self.applyMarkdownPreviewConfig();
        if (self.quick_diff_controller) |controller| {
            controller.setIgnoreTrimWhitespace(self.resolvedIgnoreTrimWhitespace());
            controller.setConfig(.{
                .decorations = self.resolvedDiffDecorations(),
                .gutter_pattern = .{ .added = true, .modified = true },
            });
        }
        if (self.repository != null) self.refreshGitStatus();
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
        if (self.theme_palette) |palette| {
            if (tab.image_preview) |pane| pane.setThemeColors(palette);
        }
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
            if (change.type == .DELETED) continue;
            // FSEvents can report a pre-existing path as ADDED on its first
            // event because it has no initial directory snapshot. For an open
            // editor that is a content change just like UPDATED.
            self.git_status_dirty = true;
            self.files_changed = true;
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
        self.working_copy_service.registerWorkingCopy(tui_editor_mod.workingCopyInterface(tab.editor)) catch {};
    }

    fn unregisterWorkingCopy(self: *Workbench, tab: *Tab) void {
        _ = self.working_copy_service.unregisterWorkingCopy(tui_editor_mod.workingCopyInterface(tab.editor));
    }

    /// Runs the registered workbench contribution phase. The app calls
    /// `after_restored` once after the first frame, matching the phase at
    /// which upstream instantiates `WorkspaceWatcher`.
    pub fn runContributionPhase(self: *Workbench, phase: contributions_mod.WorkbenchPhase) !void {
        if (phase == .after_restored and self.after_restored_ran) return;
        try self.contributions.run(phase);
        if (phase == .after_restored) self.after_restored_ran = true;
    }

    fn initAfterRestoredWorkspaceWatcher(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        try self.ensureWorkspaceWatcher();
    }

    fn ensureWorkspaceWatcher(self: *Workbench) !void {
        if (self.workspace.getWorkspace().folders.items.len == 0) return;
        if (self.configuration == null) try self.ensureConfiguration();
        const configuration = self.configuration orelse return;

        if (self.file_watcher_service == null) {
            const service = try FileWatcherService.init(self.allocator, self.io);
            errdefer service.deinit();
            _ = try service.on_did_change.listen(self, onWorkspaceFileChanges);
            self.file_watcher_service = service;
        }

        if (self.workspace_watcher == null) {
            self.workspace_watcher = try WorkspaceWatcher.init(
                self.allocator,
                configuration,
                self.workspace,
                self.file_watcher_service.?,
                .{ .context = self, .callback = reportWatcherMessage },
            );
        }
    }

    fn onWorkspaceFileChanges(changes: []const @import("../../platform/files/common/files.zig").FileChange, self: *Workbench) !void {
        self.handleFileChanges(changes);
    }

    fn reportWatcherMessage(_: *anyopaque, message: []const u8) void {
        std.log.scoped(.file_watcher).warn("{s}", .{message});
    }

    pub fn pollFileWatcher(self: *Workbench, now_ms: i64) bool {
        var changed = false;
        if (self.pollReloadJobs()) changed = true;
        if (self.sidebar) |sidebar| {
            if (sidebar.pollLoad()) changed = true;
        }
        if (self.settings_watcher) |watcher| {
            changed = watcher.poll(now_ms) catch false;
            if (changed) {
                if (self.search_view) |view| view.onConfigurationChanged();
                self.applyScmConfig();
            }
        }
        if (self.file_watcher_service) |service| {
            if (self.workspace_watcher != null) _ = service.poll();
        }
        if (self.files_changed) {
            self.files_changed = false;
            changed = true;
        }
        return changed;
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

    pub fn fileWatcherTimeout(self: *Workbench, now_ms: i64) ?u32 {
        var result: ?u32 = null;
        if (self.settings_watcher) |watcher| result = watcher.nextTimeout(now_ms);
        if (self.file_watcher_service) |service| {
            if (service.nextTimeout()) |timeout| {
                result = if (result) |current| @min(current, timeout) else timeout;
            }
        }
        return result;
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
            self.sidebar.?.setAsyncIo(self.async_io);
        }
        if (self.search_view == null) try self.initSearchFromWorkspace();
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

    /// The activity-bar ellipsis lists the entries that do not fit the rail.
    fn showActivityOverflowMenu(self: *Workbench) !void {
        const rect = self.activityRect();
        const capacity = activity_bar_mod.visibleCapacity(rect);
        if (!activity_bar_mod.overflowVisible(&self.activity_bar_part, rect)) return;
        const shown = capacity -| 1;
        _ = self.breadcrumbs_arena.reset(.retain_capacity);
        const arena = self.breadcrumbs_arena.allocator();
        var items = std.array_list.Managed(QuickPickItem).init(arena);
        var visible_index: usize = 0;
        for (self.activity_bar_part.activities.items) |activity| {
            if (!activity.visible) continue;
            defer visible_index += 1;
            if (visible_index < shown) continue;
            try items.append(.{ .item = .{
                .id = try std.fmt.allocPrint(arena, "activity:{s}", .{activity.id}),
                .label = activity.name,
            } });
        }
        if (items.items.len == 0) return;
        try self.quick_access.inputService().showPick(
            items.items,
            .{ .placeholder = "Activity Bar" },
            onActivityOverflowPick,
            self,
        );
    }

    pub fn showActivity(self: *Workbench, index: usize) !void {
        const activity = self.activity_bar_part.activityAtVisibleIndex(index) orelse return;
        if (self.sidebar == null or self.search_view == null) try self.initSidebarFromWorkspace();
        _ = try self.activity_bar_part.setActive(activity.id);
        _ = try self.sidebar_part.openPaneComposite(activity.id);
        try self.setSidebarVisible(true);
        try self.syncActivityBarVisibility();
        self.updateSidebarTitleActions();
        self.focus = .sidebar;
        self.statusbar.main_part.clearFocus();
        if (std.mem.eql(u8, activity.id, "search")) {
            if (self.search_view) |view| view.focus();
        }
        if (self.range_highlights) |highlights| highlights.removeHighlightRange();
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
        self.updateProblemsHighlight();
        if (self.breadcrumbs_control) |control| control.setFocused(false);
        self.statusbar.main_part.clearFocus();
        if (std.mem.eql(u8, self.activity_bar_part.active_id orelse "", "search")) {
            if (self.search_view) |view| view.focus();
        }
    }

    pub fn focusEditor(self: *Workbench) void {
        self.focus = .editor;
        if (self.scm_view) |view| view.blurInput();
        if (self.range_highlights) |highlights| highlights.removeHighlightRange();
        if (self.breadcrumbs_control) |control| control.setFocused(false);
        self.statusbar.main_part.clearFocus();
        if (self.search_view) |view| view.blur();
    }

    pub fn focusStatusBar(self: *Workbench) void {
        if (!self.statusBarVisible()) return;
        self.focus = .statusbar;
        self.updateProblemsHighlight();
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

    /// Upstream `workbench.actions.view.problems`: open the Problems container
    /// in the panel and move focus to the list.
    pub fn showProblems(self: *Workbench) !void {
        try self.ensureProblemsView();
        if (self.problems_view) |view| view.refresh();
        if (!try self.panel_part.openPaneComposite(PROBLEMS_CONTAINER_ID)) return;
        try self.syncPanelContainerVisibility();
        self.focus = .problems;
        self.statusbar.main_part.clearFocus();
        if (self.breadcrumbs_control) |control| control.setFocused(false);
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
            self.focus = .editor;
        }
        self.updateProblemsHighlight();
        self.layoutAll();
    }

    fn problemsVisible(self: *const Workbench) bool {
        return self.panelShown() and std.mem.eql(u8, self.activePanelId(), PROBLEMS_CONTAINER_ID);
    }

    fn problemsFocused(self: *const Workbench) bool {
        return self.focus == .problems and self.problemsVisible();
    }

    /// Hides the panel without clearing the active container, like upstream
    /// `TogglePanelAction`.
    pub fn hidePanel(self: *Workbench) void {
        self.panel_part.setHovered(null);
        self.panel_part.setVisible(false) catch {};
        if (self.focus == .terminal or self.focus == .problems) {
            self.focus = .editor;
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
            if (self.problems_view) |view| view.refresh();
            self.focus = .problems;
        } else if (std.mem.eql(u8, id, TERMINAL_CONTAINER_ID)) {
            self.focus = .terminal;
        }
        self.statusbar.main_part.clearFocus();
        if (self.breadcrumbs_control) |control| control.setFocused(false);
        if (self.search_view) |view| view.blur();
        self.updateProblemsHighlight();
        self.layoutAll();
        return true;
    }

    /// Builds the Problems badge for the panel title. The caller owns the
    /// buffers, so the returned slice is valid for one render or hit test.
    fn panelBadges(self: *Workbench, buf: *[48]u8, badges: *[1]panel_part_mod.Badge) []const panel_part_mod.Badge {
        const service = self.marker_service orelse return &.{};
        const stats = service.getStatistics();
        if (stats.errors + stats.warnings + stats.infos == 0) return &.{};
        const text = std.fmt.bufPrint(buf, "\u{2716} {d} \u{26A0} {d}", .{
            stats.errors,
            stats.warnings,
        }) catch return &.{};
        badges[0] = .{ .id = PROBLEMS_CONTAINER_ID, .text = text };
        return badges[0..1];
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
        if (!self.panelShown()) return false;
        const items = self.panel_part.pane.bar.items.items;
        var visible_count: usize = 0;
        for (items) |item| {
            if (item.visible) visible_count += 1;
        }
        if (visible_count < 2) return false;
        var current: isize = -1;
        for (items, 0..) |item, index| {
            if (!item.visible) continue;
            if (std.mem.eql(u8, item.id, self.activePanelId())) {
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
        const problems_active = std.mem.eql(u8, self.activePanelId(), PROBLEMS_CONTAINER_ID);
        _ = try self.panel_part.pane.setPaneCompositeVisible(PROBLEMS_CONTAINER_ID, problems_has_content or problems_active);

        const terminals = if (self.terminal_service) |service| service.count() else 0;
        const terminal_active = std.mem.eql(u8, self.activePanelId(), TERMINAL_CONTAINER_ID);
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
        _ = try self.openPanelContainer(TERMINAL_CONTAINER_ID);
    }

    pub fn hideTerminal(self: *Workbench) void {
        self.hidePanel();
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
        _ = try self.openPanelContainer(TERMINAL_CONTAINER_ID);
    }

    pub fn killTerminal(self: *Workbench) !void {
        const service = self.terminal_service orelse return;
        const was_active = std.mem.eql(u8, self.activePanelId(), TERMINAL_CONTAINER_ID);
        service.killActive();
        if (service.count() == 0) {
            try self.syncPanelContainerVisibility();
            if (was_active) self.hideTerminal();
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
        if (!self.panelShown()) return;
        const current = self.panelHeight();
        const available = self.workbenchRows();
        const max_height = @max(@min(available / 2, available -| 1), 1);
        const next_value = @as(isize, @intCast(current)) + delta;
        const min_height: isize = @intCast(panel_part_mod.title_height + 1);
        const next: usize = @intCast(@min(@max(next_value, min_height), @as(isize, @intCast(max_height))));
        if (next == current) return;
        self.panel_part.setSize(next) catch {};
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
        if (self.dialog != null or self.quick_access.isOpen()) return false;
        if (!self.terminalFocused()) {
            // A re-shown but empty Terminal container still owns the panel
            // focus; swallow keys instead of leaking them to the editor
            // underneath the panel.
            if (self.focus == .terminal and self.panelShown() and
                std.mem.eql(u8, self.activePanelId(), TERMINAL_CONTAINER_ID))
            {
                return true;
            }
            return false;
        }
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
        const rect = self.panelContentRect();
        const hit = terminal_panel.hitTest(service, rect, event.x, event.y);
        // Tab-strip actions are click gestures. The app enables all-motion
        // reporting (mode 1003), so motion, releases, wheel notches and
        // non-left buttons must not create, close or switch terminals.
        const left_press = event.kind == .down and event.button == .left;
        switch (hit) {
            .none => return false,
            .tab => |index| {
                self.pointer = .pointer;
                if (!left_press) return true;
                _ = service.setActive(index);
                self.focus = .terminal;
                return true;
            },
            .new_terminal => {
                self.pointer = .pointer;
                if (!left_press) return true;
                self.newTerminal() catch {};
                return true;
            },
            .kill_terminal => {
                self.pointer = .pointer;
                if (!left_press) return true;
                self.killTerminal() catch {};
                return true;
            },
            .content => {},
        }

        // Terminal content is text: the emulator owns no pointer shapes of its
        // own in this port.
        self.pointer = .text;

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
            pane.setTabsVisible(self.tabsVisibleFor(pane.tabs.items.len));
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
        const l = terminal_panel.layout(self.panelContentRect());
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
        self.disposeInactiveBreadcrumbs(pane.group.id);
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
    fn homePath(self: *const Workbench) ?[]const u8 {
        return self.home_path;
    }

    pub fn workspaceFolderPath(self: *Workbench) ?[]const u8 {
        const folders = self.workspace.getWorkspace().folders.items;
        if (folders.len == 0) return null;
        return folders[0].resource;
    }

    pub fn activeTab(self: *Workbench) ?*Tab {
        const pane = self.activePane() orelse return null;
        const tab = pane.activeTab();
        self.syncHistorySelectionTab(tab);
        return tab;
    }

    fn syncHistorySelectionTab(self: *Workbench, tab: ?*Tab) void {
        if (self.history_tab == tab) return;
        if (self.history_tab) |old_tab| {
            if (self.history_selection_listener) |listener| old_tab.removeSelectionListener(listener);
            if (self.history_content_listener) |listener| old_tab.editor.removeWorkingCopyContentListener(listener);
        }
        self.history_tab = tab;
        self.history_selection_listener = null;
        self.history_content_listener = null;
        const next = tab orelse return;
        const listener = Tab.SelectionListener{
            .context = self,
            .callback = onHistorySelectionChanged,
        };
        next.addSelectionListener(listener) catch return;
        self.history_selection_listener = listener;
        const content_listener = editor_widget.ChangeListener{ .context = self, .callback = onHistoryContentChanged };
        next.editor.addWorkingCopyContentListener(content_listener);
        self.history_content_listener = content_listener;
    }

    fn detachHistoryTab(self: *Workbench, tab: *Tab) void {
        if (self.history_tab != tab) return;
        if (self.history_selection_listener) |listener| tab.removeSelectionListener(listener);
        if (self.history_content_listener) |listener| tab.editor.removeWorkingCopyContentListener(listener);
        self.history_tab = null;
        self.history_selection_listener = null;
        self.history_content_listener = null;
    }

    fn onHistoryContentChanged(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.recordNavigationWithReason(.EDIT);
    }

    fn onHistorySelectionChanged(context: *anyopaque, reason: editor_mod.EditorPaneSelectionChangeReason) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        // Vim and other navigation sources record explicitly before moving.
        // A bare USER cursor move must not add a jump-list entry.
        if (reason == .USER) return;
        self.recordNavigationWithReason(reason);
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
        /// Open the file in a text editor even when its extension normally
        /// selects the image preview (the "Open in Text Editor" action).
        force_text: bool = false,
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
        // Keep the panel title badge and the `hideIfEmpty` tab in sync with
        // marker changes, like the markers view container in upstream.
        self.marker_listener = try marker_service.on_marker_changed.listen(self, onMarkersChanged);
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

    fn onMarkersChanged(_: MarkerChangeEvent, self: *Workbench) !void {
        try self.syncPanelContainerVisibility();
        if (self.problems_view) |view| view.refresh();
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

    /// Applies completed worker deltas for every open editor. Called on every
    /// TUI loop tick so the worker result channel is drained even while input
    /// is buffered.
    pub fn drainBackgroundTokenization(self: *Workbench) bool {
        var changed = false;
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.editor.drainBackgroundTokenization()) changed = true;
                if (tab.diff) |diff| {
                    if (diff.widget.original_editor.drainBackgroundTokenization()) changed = true;
                }
            }
        }
        return changed;
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
                if (tab.diff) |diff| {
                    _ = diff.widget.original_editor.pollBackgroundTokenization();
                }
            }
        }
        return active_changed;
    }

    pub fn backgroundTokenizationPending(self: *Workbench) bool {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.editor.backgroundTokenizationPending()) return true;
                if (tab.diff) |diff| {
                    if (diff.widget.original_editor.backgroundTokenizationPending()) return true;
                }
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
        if (self.scm_container) |container| {
            container.deinit();
            self.allocator.destroy(container);
            self.scm_container = null;
        }
        if (self.scm_view_model) |model| {
            model.deinit();
            self.allocator.destroy(model);
            self.scm_view_model = null;
        }
        if (self.scm_panes) |panes| {
            self.allocator.free(panes);
            self.scm_panes = null;
        }
        if (self.scm_history_view) |view| {
            view.deinit();
            self.allocator.destroy(view);
            self.scm_history_view = null;
        }
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
        if (self.repository) |provider| {
            provider.destroy();
            self.repository = null;
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
        if (self.git) |cli| {
            cli.deinit();
            self.git = null;
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
        if (self.git != null) return;
        const root_value = self.workspaceFolderPath() orelse return;
        if (self.configuration) |configuration| {
            if (!configuration.getBool("git.enabled", true)) return;
        }

        var options = git_mod.Options{
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

        const cli = git_mod.Git.init(self.allocator, options) catch return;
        self.git = cli;
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

        const provider = try repository_mod.Repository.create(
            self.allocator,
            cli,
            concrete,
            root,
            .{
                .context = self,
                .open_change = providerOpenChange,
            },
        );
        self.repository = provider;
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

        const scm_view = try self.allocator.create(scm_view_mod.SCMViewPane);
        const scm_interface = scm_service.interface();
        // The view only reads the service through the interface; keep a stable
        // copy because `interface()` returns by value.
        const service_copy = try self.allocator.create(scm_common.ISCMService);
        service_copy.* = scm_interface;
        self.scm_interface = service_copy;
        scm_view.* = scm_view_mod.SCMViewPane.init(self.allocator, service_copy, .{
            .context = self,
            .open_change = scmViewOpen,
            .refresh = scmRefresh,
            .focus_editor = scmFocusEditor,
            .commit = scmViewCommit,
            .status = scmViewStatus,
        });
        self.scm_view = scm_view;
        scm_view.setConfig(self.scmChangesConfig());

        // Graph view and the collapsible SCM view container. The existing
        // terminal ViewContainerModel only holds the portable visible/collapsed
        // state; the workbench supplies the panes.
        const history_view = try scm_history_view_mod.SCMHistoryViewPane.init(
            self.allocator,
            .{
                .context = self,
                .open_change = historyOpenChange,
                .focus_editor = scmFocusEditor,
                .pick_refs = historyPickRefs,
            },
            self.quick_diff_storage,
        );
        self.scm_history_view = history_view;
        history_view.setConfig(self.scmHistoryConfig());
        if (self.theme_palette) |palette| history_view.setThemeColors(palette);
        if (provider.historyProvider()) |history_provider| {
            history_view.setProvider(history_provider.interface());
        }

        const view_model = try self.allocator.create(view_container_model_mod.ViewContainerModel);
        view_model.* = view_container_model_mod.ViewContainerModel.init(self.allocator, .{
            .id = "scm",
            .title = "Source Control",
            .icon = "",
        });
        self.scm_view_model = view_model;
        try view_model.addView(.{ .id = "changes", .name = "Changes", .order = 1, .weight = 40 });
        try view_model.addView(.{
            .id = "graph",
            .name = "Graph",
            .visible = provider.historyProvider() != null,
            .order = 2,
            .weight = 40,
        });
        view_model.setActiveView("changes");

        const panes = try self.allocator.alloc(view_pane_container_mod.Pane, 2);
        panes[0] = .{
            .id = "changes",
            .title = "Changes",
            .context = self,
            .render_body = scmChangesRenderBody,
            .handle_key = scmChangesHandleKey,
            .handle_mouse = scmChangesHandleMouse,
            .title_actions = scmChangesTitleActions,
        };
        panes[1] = .{
            .id = "graph",
            .title = "Graph",
            .context = self,
            .render_body = scmHistoryRenderBody,
            .handle_key = scmHistoryHandleKey,
            .handle_mouse = scmHistoryHandleMouse,
            .title_actions = scmHistoryTitleActions,
        };
        self.scm_panes = panes;
        self.scm_container = try view_pane_container_mod.ViewPaneContainer.init(
            self.allocator,
            view_model,
            panes,
        );

        self.git_status_accessor = try self.statusbar.addEntry(.{
            .name = "Source Control",
            .text = "",
            .command = .{ .id = "workbench.view.scm" },
        }, "workbench.scm.branch", .left, .{ .number = 100 });
        self.next_git_refresh = time_compat.milliTimestamp();
        self.syncGitStatus();
        self.syncGitActivity();
        self.syncScmInput();
        if (self.scm_view) |view| view.refresh();
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
        if (self.repository == null) return changed;
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
        return self.repository != null;
    }

    /// Re-reads git status, the SCM rows, the quick-diff baselines, the
    /// branch/status entry and the activity badge.
    pub fn refreshGitStatus(self: *Workbench) void {
        const provider = self.repository orelse return;
        provider.refresh() catch {};
        self.syncScmInput();
        if (self.scm_view) |view| view.refresh();
        if (provider.refreshHistoryRefs(true)) {
            if (self.scm_history_view) |view| view.onHistoryItemRefsChanged(true);
        }
        if (self.quick_diff_controller) |controller| _ = controller.refreshAll();
        self.syncGitStatus();
        self.syncGitActivity();
    }

    fn syncGitStatus(self: *Workbench) void {
        const accessor = self.git_status_accessor orelse return;
        const provider = self.repository orelse {
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
        const provider = self.repository orelse return;
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
        const provider = self.repository orelse return error.NoRepository;
        const root = self.git_root orelse return error.NoRepository;
        _ = provider;
        const relative = relativeToRoot(path, root) orelse return error.OutsideRepository;
        const git = self.git orelse return error.NoGit;

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
        const root = self.git_root orelse return error.NoRepository;
        const git = self.git orelse return error.NoGit;
        const relative_right = if (std.fs.path.isAbsolute(path))
            relativeToRoot(path, root) orelse return error.OutsideRepository
        else
            path;
        const relative_left = if (original_path) |value|
            if (std.fs.path.isAbsolute(value))
                relativeToRoot(value, root) orelse relative_right
            else
                value
        else
            relative_right;

        const left_text = if (left_rev) |revision| blk: {
            const value = git.readRefAt(self.allocator, root, relative_left, revision) catch null;
            break :blk value orelse try self.allocator.dupe(u8, "");
        } else try self.allocator.dupe(u8, "");
        defer self.allocator.free(left_text);
        const right_text = blk: {
            const value = git.readRefAt(self.allocator, root, relative_right, right_rev) catch null;
            break :blk value orelse try self.allocator.dupe(u8, "");
        };
        defer self.allocator.free(right_text);

        try self.openSnapshotDiff(path, left_text, right_text, left_label, right_label);
    }

    fn openSnapshotDiff(
        self: *Workbench,
        path: []const u8,
        original_text: []const u8,
        modified_text: []const u8,
        left_label: []const u8,
        right_label: []const u8,
    ) !void {
        if (self.findDiffTab(path, left_label, right_label)) |tab| {
            const pane = self.activePane();
            const dims = if (pane) |value| editorDimensions(self, value) else Dimensions{ .width = self.cols, .height = self.editorRows() };
            try tab.diff.?.replace(original_text, modified_text, dims.width, dims.height, self.diffEditorOptions());
            tab.syncDiffViews();
            if (pane) |value| {
                try value.activateTab(tab);
                tab.layoutCells(dims.width, dims.height);
            }
            tab.focusEditor();
            self.refreshStatus();
            return;
        }

        const pane = self.activePane();
        const dims = if (pane) |value| editorDimensions(self, value) else Dimensions{ .width = self.cols, .height = self.editorRows() };
        const view = try text_diff_editor_mod.DiffView.create(
            self.allocator,
            self.io,
            .{
                .original_path = path,
                .modified_path = path,
                .original_text = original_text,
                .modified_text = modified_text,
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
        git: *git_mod.Git,
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
        git: *git_mod.Git,
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
        const kind: git_mod.RefKind = switch (ref) {
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

    fn openScmChange(self: *Workbench, provider: *repository_mod.Repository, resource: *repository_mod.GitScmResource) !void {
        _ = provider;
        switch (resource.kind) {
            .merge => try self.openPath(resource.absolute_path),
            .untracked => try self.openDiff(resource.absolute_path, .empty, .working),
            .index => try self.openDiff(resource.absolute_path, .head, .index),
            .working => {
                // If the path is staged as well, compare index->working; an
                // unstaged path compares HEAD->working.
                const staged = self.repository.?.repository.stateRef().index_changes;
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

    fn providerOpenChange(context: *anyopaque, provider: *repository_mod.Repository, resource: *repository_mod.GitScmResource) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return self.openScmChange(provider, resource);
    }

    fn scmOpenChange(context: *anyopaque, resource: *scm_common.ISCMResource) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const provider = self.repository orelse return;
        const git_resource = @as(*repository_mod.GitScmResource, @ptrCast(@alignCast(resource.context)));
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

    fn scmViewCommit(context: *anyopaque, message: []const u8) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return self.commitScmMessage(message);
    }

    fn scmViewStatus(context: *anyopaque, message: []const u8) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.setStatusHint("{s}", .{message});
    }

    /// Commits `message`. With staged changes the index is committed as-is;
    /// when the index is empty the terminal substitutes upstream's smart
    /// commit prompt by staging the changed files (honoring
    /// `git.smartCommitChanges`), then commits.
    fn commitScmMessage(self: *Workbench, message: []const u8) !void {
        const provider = self.repository orelse return error.NoRepository;
        const state = provider.repository.stateRef();
        if (message.len == 0) {
            self.setStatusHint("Commit message is required", .{});
            return error.EmptyCommitMessage;
        }
        if (state.merge_changes.len > 0) {
            self.setStatusHint("Resolve the merge conflicts before committing", .{});
            return error.UnresolvedConflicts;
        }
        const total = state.index_changes.len +
            state.working_tree_changes.len +
            state.untracked_changes.len;
        if (total == 0) {
            self.setStatusHint("No changes to commit", .{});
            return error.NoChanges;
        }

        const git = provider.git orelse {
            self.setStatusHint("Commit failed: Git is not available", .{});
            return error.NoGit;
        };

        if (state.index_changes.len > 0) {
            git.commitFiles(provider.root, &.{}, message, .{}) catch |err| {
                self.setStatusHint("Commit failed: {s}", .{@errorName(err)});
                return err;
            };
            self.setStatusHint("Committed", .{});
            return;
        }

        var tracked_only = false;
        if (self.configuration) |configuration| {
            if (configuration.getValue("git.smartCommitChanges", .{})) |value| {
                switch (value.*) {
                    .string => |text| tracked_only = std.mem.eql(u8, text, "tracked"),
                    else => {},
                }
            }
        }
        var files = std.array_list.Managed([]const u8).init(self.allocator);
        defer files.deinit();
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        const working_paths = try uniqueChangePaths(&seen, state.working_tree_changes, files.allocator);
        defer files.allocator.free(working_paths);
        try files.appendSlice(working_paths);
        if (!tracked_only) {
            const untracked_paths = try uniqueChangePaths(&seen, state.untracked_changes, files.allocator);
            defer files.allocator.free(untracked_paths);
            try files.appendSlice(untracked_paths);
        }
        if (files.items.len == 0) {
            self.setStatusHint("No tracked changes to commit", .{});
            return error.NothingStaged;
        }
        git.commitFiles(provider.root, files.items, message, .{}) catch |err| {
            self.setStatusHint("Commit failed: {s}", .{@errorName(err)});
            return err;
        };
        self.setStatusHint("Committed", .{});
    }

    fn uniqueChangePaths(
        seen: *std.StringHashMap(void),
        changes: []const repository_mod.GitChange,
        allocator: Allocator,
    ) ![]const []const u8 {
        var paths = std.array_list.Managed([]const u8).init(allocator);
        errdefer paths.deinit();
        for (changes) |change| {
            if (change.path.len == 0) continue;
            if (seen.contains(change.path)) continue;
            try seen.put(change.path, {});
            try paths.append(change.path);
        }
        return paths.toOwnedSlice();
    }

    /// Builds the Graph configuration from the user settings.
    pub fn scmHistoryConfig(self: *Workbench) scm_history_view_mod.Config {
        var config = scm_history_view_mod.Config{};
        const configuration = self.configuration orelse return config;
        if (configuration.getValue("scm.graph.pageSize", .{})) |value| {
            switch (value.*) {
                .integer => |number| config.page_size = @intCast(@max(@min(number, 1000), 1)),
                else => {},
            }
        }
        if (configuration.getValue("scm.graph.pageOnScroll", .{})) |value| {
            switch (value.*) {
                .bool => |enabled| config.page_on_scroll = enabled,
                else => {},
            }
        }
        if (configuration.getValue("scm.graph.badges", .{})) |value| {
            switch (value.*) {
                .string => |text| config.badges_all = std.mem.eql(u8, text, "all"),
                else => {},
            }
        }
        if (configuration.getValue("scm.graph.showIncomingChanges", .{})) |value| {
            switch (value.*) {
                .bool => |enabled| config.show_incoming_changes = enabled,
                else => {},
            }
        }
        if (configuration.getValue("scm.graph.showOutgoingChanges", .{})) |value| {
            switch (value.*) {
                .bool => |enabled| config.show_outgoing_changes = enabled,
                else => {},
            }
        }
        if (configuration.getValue("scm.defaultViewMode", .{})) |value| {
            switch (value.*) {
                .string => |text| config.default_view_mode = if (std.mem.eql(u8, text, "tree")) .tree else .list,
                else => {},
            }
        }
        if (configuration.getValue("scm.compactFolders", .{})) |value| {
            switch (value.*) {
                .bool => |enabled| config.compact_folders = enabled,
                else => {},
            }
        }
        if (configuration.getValue("git.commitShortHashLength", .{})) |value| {
            switch (value.*) {
                .integer => |number| config.short_hash_length = @intCast(@max(number, 1)),
                else => {},
            }
        }
        return config;
    }

    /// Re-applies the SCM settings the terminal views understand. A view keeps
    /// an explicit list/tree or sort choice made through its title action or
    /// command, like upstream's workspace storage override.
    fn applyScmConfig(self: *Workbench) void {
        const config = self.scmHistoryConfig();
        if (self.scm_history_view) |view| view.setConfig(config);
        self.syncScmInput();
        if (self.scm_view) |view| view.setConfig(self.scmChangesConfig());
        if (self.repository) |provider| provider.setCommitShortHashLength(config.short_hash_length);
    }

    /// Updates the Source Control input model from Git settings and the
    /// current branch: `git.showCommitInput` controls visibility and the
    /// placeholder mirrors the extension's
    /// `Message ({0} to commit on "{1}")` template. The terminal uses Enter
    /// as the accept key because a terminal cannot reliably distinguish
    /// Ctrl+Enter from Enter.
    fn syncScmInput(self: *Workbench) void {
        const interface = self.scm_interface orelse return;
        const repositories = interface.repositories();
        if (repositories.len == 0) return;
        const input = repositories[0].input;
        const visible = if (self.configuration) |configuration|
            configuration.getBool("git.showCommitInput", true)
        else
            true;
        input.setVisible(visible);
        var branch: ?[]const u8 = null;
        if (self.repository) |provider| branch = provider.interface().detail;
        const placeholder = if (branch) |name|
            std.fmt.bufPrint(&self.scm_placeholder_buf, "Message (Enter to commit on \"{s}\")", .{name}) catch "Message (Enter to commit)"
        else
            "Message (Enter to commit)";
        input.setPlaceholder(placeholder);
    }

    fn scmChangesConfig(self: *Workbench) scm_view_mod.Config {
        var config = scm_view_mod.Config{};
        const configuration = self.configuration orelse return config;
        if (configuration.getValue("scm.defaultViewMode", .{})) |value| {
            switch (value.*) {
                .string => |text| config.default_view_mode = if (std.mem.eql(u8, text, "tree")) .tree else .list,
                else => {},
            }
        }
        if (configuration.getValue("scm.defaultViewSortKey", .{})) |value| {
            switch (value.*) {
                .string => |text| {
                    if (std.mem.eql(u8, text, "name")) {
                        config.default_view_sort_key = .name;
                    } else if (std.mem.eql(u8, text, "status")) {
                        config.default_view_sort_key = .status;
                    } else {
                        config.default_view_sort_key = .path;
                    }
                },
                else => {},
            }
        }
        config.always_show_repositories = configuration.getBool("scm.alwaysShowRepositories", false);
        config.compact_folders = configuration.getBool("scm.compactFolders", true);
        config.show_input_action_button = configuration.getBool("scm.showInputActionButton", true);
        if (configuration.getValue("scm.providerCountBadge", .{})) |value| {
            switch (value.*) {
                .string => |text| {
                    if (std.mem.eql(u8, text, "visible")) {
                        config.provider_count_badge = .visible;
                    } else if (std.mem.eql(u8, text, "auto")) {
                        config.provider_count_badge = .auto;
                    } else {
                        config.provider_count_badge = .hidden;
                    }
                },
                else => {},
            }
        }
        return config;
    }

    fn scmChangesRenderBody(
        context: *anyopaque,
        grid: *ui.CellGrid,
        rect: ui.Rect,
        focused: bool,
    ) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm_view orelse return;
        if (self.theme_palette) |palette| view.setThemeColors(palette);
        try view.render(grid, rect, focused, .{ .show_header = false });
    }

    fn scmChangesHandleKey(context: *anyopaque, event: *ui.KeyEvent) anyerror!bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm_view orelse return false;
        return view.handleKey(event);
    }

    fn scmChangesHandleMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) anyerror!bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm_view orelse return false;
        return view.handleMouse(@constCast(event), rect);
    }

    fn scmChangesTitleActions(context: *anyopaque) []const views_mod.TitleAction {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm_view orelse return &.{};
        return view.titleActions();
    }

    fn scmHistoryRenderBody(
        context: *anyopaque,
        grid: *ui.CellGrid,
        rect: ui.Rect,
        focused: bool,
    ) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm_history_view orelse return;
        if (self.theme_palette) |palette| view.setThemeColors(palette);
        try view.render(grid, rect, focused);
    }

    fn scmHistoryHandleKey(context: *anyopaque, event: *ui.KeyEvent) anyerror!bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm_history_view orelse return false;
        return view.handleKey(event);
    }

    fn scmHistoryHandleMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) anyerror!bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm_history_view orelse return false;
        return view.handleMouse(event, rect);
    }

    fn scmHistoryTitleActions(context: *anyopaque) []const views_mod.TitleAction {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const view = self.scm_history_view orelse return &.{};
        return view.titleActions();
    }

    fn historyOpenChange(
        context: *anyopaque,
        history_item: *const scm_common_history.ISCMHistoryItem,
        change: *const scm_common_history.ISCMHistoryItemChange,
    ) anyerror!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const display = history_item.display_id orelse history_item.id;
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
                history_item.id,
                parent_label,
                display,
            );
        }
        return self.openRefDiff(
            change.path,
            change.original_path,
            null,
            history_item.id,
            "Empty",
            display,
        );
    }

    fn historyPickRefs(context: *anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.showHistoryRefPicker();
    }

    fn showHistoryRefPicker(self: *Workbench) void {
        const view = self.scm_history_view orelse return;
        const provider = view.provider orelse return;
        const refs = provider.provideHistoryItemRefs(self.allocator, null) catch return;
        defer scm_common_history.freeHistoryItemRefs(self.allocator, refs);

        const state = self.allocator.create(PickHandlerState) catch return;
        state.* = .{
            .workbench = self,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
        };
        errdefer freeRefPickState(state);
        const arena = state.arena.allocator();
        var items = std.array_list.Managed(QuickPickItem).init(arena);
        items.append(.{ .item = .{ .id = "all", .label = "All", .description = "All history item references" } }) catch return;
        items.append(.{ .item = .{ .id = "auto", .label = "Auto", .description = "Current history item references" } }) catch return;
        if (refs.len > 0) items.append(.{ .separator = .{ .label = "References" } }) catch return;
        for (refs) |reference| {
            const label = arena.dupe(u8, reference.name) catch continue;
            const description: []const u8 = if (reference.description) |value| arena.dupe(u8, value) catch "" else "";
            items.append(.{ .item = .{ .id = reference.id, .label = label, .description = description } }) catch continue;
        }
        state.items = items.items;
        self.quick_access.inputService().showPick(
            state.items,
            .{
                .placeholder = "Select a history item reference to view",
                .cleanup = freeRefPickState,
                .cleanup_context = state,
            },
            refPickAccepted,
            state,
        ) catch {};
    }

    const PickHandlerState = struct {
        workbench: *Workbench,
        arena: std.heap.ArenaAllocator,
        items: []QuickPickItem = &.{},
    };

    fn freeRefPickState(context: *anyopaque) void {
        const state: *PickHandlerState = @ptrCast(@alignCast(context));
        const allocator = state.arena.child_allocator;
        state.arena.deinit();
        allocator.destroy(state);
    }

    fn refPickAccepted(context: *anyopaque, picker: *QuickPick) anyerror!void {
        const state: *PickHandlerState = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse picker.activeItem() orelse return;
        const view = state.workbench.scm_history_view orelse return;
        if (std.mem.eql(u8, item.id, "all")) {
            view.setFilterAll();
        } else if (std.mem.eql(u8, item.id, "auto")) {
            view.setFilterAuto();
        } else {
            view.setFilterRefs(&.{item.id}) catch {};
        }
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

    const ShowTabs = enum { none, single, multiple };

    fn findAddExtraSpaceOnTop(self: *Workbench) bool {
        return self.findBoolSetting("editor.find.addExtraSpaceOnTop", true);
    }

    fn findAutoFindInSelection(self: *Workbench) @import("../../editor/contrib/find/browser/findController.zig").AutoFindInSelection {
        const configuration = self.configuration orelse return .never;
        const value = configuration.getValue("editor.find.autoFindInSelection", .{}) orelse return .never;
        return switch (value.*) {
            .string => |text| if (std.mem.eql(u8, text, "always"))
                .always
            else if (std.mem.eql(u8, text, "multiline"))
                .multiline
            else
                .never,
            else => .never,
        };
    }

    fn findSeedSearchStringFromSelection(self: *Workbench) @import("../../editor/contrib/find/browser/findController.zig").SeedSearchString {
        const configuration = self.configuration orelse return .always;
        const value = configuration.getValue("editor.find.seedSearchStringFromSelection", .{}) orelse return .always;
        return switch (value.*) {
            .string => |text| if (std.mem.eql(u8, text, "never"))
                .never
            else if (std.mem.eql(u8, text, "selection"))
                .selection
            else
                .always,
            else => .always,
        };
    }

    fn findHistoryEnabled(self: *Workbench, key: []const u8) bool {
        const configuration = self.configuration orelse return true;
        const value = configuration.getValue(key, .{}) orelse return true;
        return switch (value.*) {
            .string => |text| !std.mem.eql(u8, text, "never"),
            else => true,
        };
    }

    fn findOnType(self: *Workbench) bool {
        return self.findBoolSetting("editor.find.findOnType", true);
    }

    fn findCloseOnResult(self: *Workbench) bool {
        return self.findBoolSetting("editor.find.closeOnResult", false);
    }

    fn findLoop(self: *Workbench) bool {
        return self.findBoolSetting("editor.find.loop", true);
    }

    fn findBoolSetting(self: *Workbench, key: []const u8, default: bool) bool {
        const configuration = self.configuration orelse return default;
        const value = configuration.getValue(key, .{}) orelse return default;
        return switch (value.*) {
            .bool => |enabled| enabled,
            else => default,
        };
    }

    fn editorShowTabs(self: *Workbench) ShowTabs {
        const configuration = self.configuration orelse return .multiple;
        const value = configuration.getValue("workbench.editor.showTabs", .{}) orelse return .multiple;
        return switch (value.*) {
            .string => |text| if (std.mem.eql(u8, text, "none"))
                .none
            else if (std.mem.eql(u8, text, "single"))
                .single
            else
                .multiple,
            else => .multiple,
        };
    }

    fn tabsVisibleFor(self: *Workbench, tab_count: usize) bool {
        return switch (self.editorShowTabs()) {
            .none => false,
            .single => tab_count > 1,
            .multiple => true,
        };
    }

    fn editorTabSizing(self: *Workbench) tab_bar.TabSizing {
        const configuration = self.configuration orelse return .fit;
        const value = configuration.getValue("workbench.editor.tabSizing", .{}) orelse return .fit;
        return switch (value.*) {
            .string => |text| if (std.mem.eql(u8, text, "shrink"))
                .shrink
            else if (std.mem.eql(u8, text, "fixed"))
                .fixed
            else
                .fit,
            else => .fit,
        };
    }

    fn editorTabCloseButton(self: *Workbench) []const u8 {
        const configuration = self.configuration orelse return "right";
        const value = configuration.getValue("workbench.editor.tabCloseButton", .{}) orelse return "right";
        return switch (value.*) {
            .string => |text| text,
            else => "right",
        };
    }

    fn tabCloseButtonVisible(setting: []const u8) bool {
        return !std.mem.eql(u8, setting, "off");
    }

    fn editorLabelFormat(self: *Workbench) []const u8 {
        const configuration = self.configuration orelse return "default";
        const value = configuration.getValue("workbench.editor.labelFormat", .{}) orelse return "default";
        return switch (value.*) {
            .string => |text| text,
            else => "default",
        };
    }

    /// Upstream `workbench.editor.labelFormat`: `default` shows a directory
    /// only for duplicate names, `short` the parent directory, `medium` the
    /// workspace-relative directory and `long` the absolute directory.
    fn tabDescription(self: *Workbench, path: []const u8, duplicate: bool, format: []const u8) !?[]u8 {
        if (path.len == 0) return null;
        const dir = std.fs.path.dirname(path) orelse return null;
        var description: []const u8 = "";
        if (std.mem.eql(u8, format, "short")) {
            description = std.fs.path.basename(dir);
        } else if (std.mem.eql(u8, format, "medium")) {
            if (self.workspaceFolderPath()) |root| {
                if (relativeToRoot(path, root)) |relative| {
                    description = std.fs.path.dirname(relative) orelse "";
                } else {
                    description = dir;
                }
            } else {
                description = dir;
            }
        } else if (std.mem.eql(u8, format, "long")) {
            description = dir;
        } else if (duplicate) {
            // The default label service uses the parent folder name for a
            // duplicate label; keep the terminal form compact.
            description = std.fs.path.basename(dir);
        }
        if (description.len == 0 or std.mem.eql(u8, description, ".")) return null;
        return try self.allocator.dupe(u8, description);
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

    const HistorySelectionDto = struct {
        start_line: usize,
        start_column: usize,
        end_line: usize,
        end_column: usize,
        selection_start_line: usize,
        selection_start_column: usize,
        position_line: usize,
        position_column: usize,
    };

    const HistoryNavigationDto = struct {
        group_id: u32,
        path: []const u8,
        top_view_line: usize = 1,
        selection: ?HistorySelectionDto = null,
    };

    const HistoryClosedDto = struct {
        path: []const u8,
        group_id: u32,
        index: usize,
        sticky: bool,
        pinned: bool,
        batch_id: u64,
    };

    const HistoryStateDto = struct {
        version: u32 = 1,
        recent: []const []const u8 = &.{},
        navigation: []const HistoryNavigationDto = &.{},
        closed: []const HistoryClosedDto = &.{},
    };

    pub fn setHistoryStatePath(self: *Workbench, path: []const u8) !void {
        if (self.history_state_path) |old| self.allocator.free(old);
        self.history_state_path = try self.allocator.dupe(u8, path);
        self.loadHistoryState() catch {};
    }

    fn saveHistoryState(self: *Workbench) !void {
        const path = self.history_state_path orelse return;
        if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        var recent = std.array_list.Managed([]const u8).init(self.allocator);
        defer recent.deinit();
        for (self.history.getHistory()) |entry| try recent.append(entry);
        var navigation = std.array_list.Managed(HistoryNavigationDto).init(self.allocator);
        defer navigation.deinit();
        for (self.history.default_stacks.selections.entries.items) |entry| {
            try navigation.append(.{
                .group_id = entry.group_id,
                .path = entry.path,
                .top_view_line = entry.top_view_line,
                .selection = if (entry.selection) |selection| if (std.mem.eql(u8, selection.kind, "text")) blk: {
                    const text_selection: *text_editor_selection_mod.TextEditorPaneSelection = @ptrCast(@alignCast(selection.context));
                    break :blk .{
                        .start_line = text_selection.selection.startLineNumber,
                        .start_column = text_selection.selection.startColumn,
                        .end_line = text_selection.selection.endLineNumber,
                        .end_column = text_selection.selection.endColumn,
                        .selection_start_line = text_selection.selection.selectionStartLineNumber,
                        .selection_start_column = text_selection.selection.selectionStartColumn,
                        .position_line = text_selection.selection.positionLineNumber,
                        .position_column = text_selection.selection.positionColumn,
                    };
                } else null else null,
            });
        }
        var closed = std.array_list.Managed(HistoryClosedDto).init(self.allocator);
        defer closed.deinit();
        for (self.history.closed_editors.items) |entry| {
            try closed.append(.{
                .path = entry.path,
                .group_id = entry.group_id,
                .index = entry.index,
                .sticky = entry.sticky,
                .pinned = entry.pinned,
                .batch_id = entry.batch_id,
            });
        }
        const dto = HistoryStateDto{ .recent = recent.items, .navigation = navigation.items, .closed = closed.items };
        var out: Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(dto, .{}, &out.writer);
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = out.written() });
    }

    fn loadHistoryState(self: *Workbench) !void {
        const path = self.history_state_path orelse return;
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(8 * 1024 * 1024)) catch return;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(HistoryStateDto, self.allocator, bytes, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value.version != 1) return;
        for (parsed.value.recent) |entry| self.history.add(entry) catch {};
        for (parsed.value.navigation) |entry| {
            var selection: ?editor_mod.IEditorPaneSelection = null;
            if (entry.selection) |sel| {
                const snapshot = try text_editor_selection_mod.TextEditorPaneSelection.create(self.allocator, Selection.init(
                    sel.selection_start_line,
                    sel.selection_start_column,
                    sel.position_line,
                    sel.position_column,
                ));
                selection = snapshot.interface();
            }
            self.history.recordNavigation(entry.group_id, entry.path, selection, entry.top_view_line, .PROGRAMMATIC) catch {
                if (selection) |iface| iface.dispose();
            };
        }
        for (parsed.value.closed) |entry| {
            self.history.recordClosedEditor(.{
                .path = self.allocator.dupe(u8, entry.path) catch continue,
                .group_id = entry.group_id,
                .index = entry.index,
                .sticky = entry.sticky,
                .pinned = entry.pinned,
                .batch_id = entry.batch_id,
            }) catch {};
        }
    }

    /// Snapshots the active editor's pane selection into the ported editor
    /// navigation history. Called before a jump or before an editor switch.
    pub fn recordNavigation(self: *Workbench) void {
        self.recordNavigationWithReason(.USER);
    }

    pub fn recordNavigationWithReason(self: *Workbench, reason: editor_mod.EditorPaneSelectionChangeReason) void {
        if (self.history_navigating) return;
        const tab = self.activeTab() orelse return;
        const selections = tab.editor.getSelections() catch return;
        defer self.allocator.free(selections);
        if (selections.len == 0) return;
        const group_id = self.service.activeGroup().id;
        const selection = text_editor_selection_mod.TextEditorPaneSelection.create(self.allocator, selections[0]) catch return;
        var iface = selection.interface();
        self.history.recordNavigation(group_id, tab.editor.path, iface, tab.editor.topViewLine(), reason) catch {
            iface.dispose();
        };
    }

    pub fn goBackInHistory(self: *Workbench) bool {
        const tab = self.activeTab() orelse return false;
        const group_id = self.service.activeGroup().id;
        // The active location is the destination of a forward navigation and
        // must be in the stack before stepping back.
        self.recordNavigationWithReason(.NAVIGATION);
        const entry = self.history.goBack(.DEFAULT, .NONE, group_id, tab.editor.path) orelse return false;
        self.restoreNavigation(entry);
        return true;
    }

    pub fn goForwardInHistory(self: *Workbench) bool {
        const tab = self.activeTab() orelse return false;
        const group_id = self.service.activeGroup().id;
        const entry = self.history.goForward(.DEFAULT, .NONE, group_id, tab.editor.path) orelse return false;
        self.restoreNavigation(entry);
        return true;
    }

    fn restoreNavigation(self: *Workbench, entry: *history_mod.EditorNavigationStackEntry) void {
        if (self.history_navigating) return;
        self.history_navigating = true;
        defer self.history_navigating = false;

        var pane: ?*GroupPane = null;
        for (self.part.group_views.items) |candidate| {
            if (candidate.group.id == entry.group_id) {
                pane = candidate;
                break;
            }
        }
        if (pane) |target_pane| self.service.activateGroup(target_pane.group);

        if (self.activeTab() == null or !self.samePath(self.activeTab().?.editor.path, entry.path)) {
            self.openPath(entry.path) catch |err| {
                if (self.activeTab()) |tab| tab.editor.setMessage("navigation restore failed: {s}", .{@errorName(err)});
                return;
            };
        } else if (pane) |target_pane| {
            if (target_pane.activeTab()) |target| {
                target_pane.activateTab(target) catch {};
                target.focusEditor();
            }
        }

        const tab = self.activeTab() orelse return;
        if (entry.selection) |selection| {
            const options = selection.restore(.{});
            if (options.selection) |restored| {
                tab.editor.setTextEditorSelectionSource(.PROGRAMMATIC);
                tab.editor.setSelections(&[_]Selection{restored}) catch {};
            }
        }
        _ = tab.editor.setTopViewLine(entry.top_view_line);
        self.focusEditor();
        tab.focusEditor();
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

    /// Finds an already-open image preview tab for `path`.
    pub fn findOpenImageInput(self: *Workbench, path: []const u8) ?*ImagePreviewEditorInput {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                const input = tab.image_input orelse continue;
                if (!self.samePath(input.path, path)) continue;
                if (!pane.group.model.contains(.{ .input = &input.base }, .{})) continue;
                return input;
            }
        }
        return null;
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
            tab.focusEditor();
        }
        try self.history.add(path);
        self.pruneTabs(pane);
    }

    fn openImagePath(self: *Workbench, path: []const u8, options: OpenOptions, async_io: ?Io) !void {
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
                tab.focusEditor();
            }
            try self.history.add(path);
            self.pruneTabs(pane);
            return;
        }

        const tab = try Tab.initImageFromInput(self.allocator, self.io, input, self.cols, self.editorContentHeight(), &self.images, async_io);
        try tab.view.setStatusBarVisible(false);
        try pane.addTab(tab);
        self.applyEditorSettingsToTab(tab);
        try pane.activateTab(tab);
        self.focusEditor();
        tab.focusEditor();
        try self.history.add(path);
        self.pruneTabs(pane);
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
            tab.setImageRuntime(&self.images);
            if (self.language_features) |features| tab.attachLanguageRegistry(features);
            try tab.ensureControllers();
            tab.focusEditor();
        }
        try self.history.add(path);
        self.pruneTabs(pane);
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
        tab.setImageRuntime(&self.images);
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

    /// The Io used for interactive reads and network work. Callers pass this
    /// explicitly to `io.async`; it is deliberately separate from `io` so the
    /// async pool does not fall back to inline execution on the TUI thread.
    pub fn asyncIo(self: *const Workbench) Io {
        return self.async_io;
    }

    /// Interactive open: reads/decodes on the async Io and applies the result
    /// from `pollAsyncReads`. The synchronous `openPath` remains for startup,
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
            self.openImagePath(path, options, self.async_io) catch |err| {
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

        const job = self.allocator.create(OpenJob) catch {
            self.setStatusHint("Open failed: out of memory", .{});
            return;
        };
        const path_copy = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(job);
            self.setStatusHint("Open failed: out of memory", .{});
            return;
        };
        self.open_generation += 1;
        job.* = .{
            .owner = self,
            .future = undefined,
            .path = path_copy,
            .generation = self.open_generation,
            .options = options,
        };
        job.future = self.async_io.async(runOpenJob, .{job});
        self.pending_open = job;
        self.setStatusHint("Opening {s}...", .{std.fs.path.basename(path)});
    }

    fn cancelPendingOpen(self: *Workbench) void {
        const job = self.pending_open orelse return;
        self.pending_open = null;
        const outcome = job.future.cancel(self.async_io);
        self.freeOpenOutcome(outcome);
        self.allocator.free(job.path);
        self.allocator.destroy(job);
    }

    /// Starts one external-change reload per path. Results are applied by
    /// `pollReloadJobs` after resolving the tab again.
    fn requestFileReload(self: *Workbench, path: []const u8) void {
        for (self.reload_jobs.items) |job| {
            if (self.samePath(job.path, path)) return;
        }
        const path_copy = self.allocator.dupe(u8, path) catch return;
        const job = self.allocator.create(ReloadJob) catch {
            self.allocator.free(path_copy);
            return;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.async_io,
            .future = undefined,
            .path = path_copy,
        };
        job.future = self.async_io.async(runReloadJob, .{job});
        self.reload_jobs.append(job) catch {
            const result = job.future.cancel(self.async_io);
            if (result == .content) {
                var content = result.content;
                content.deinit(self.allocator);
            }
            self.allocator.free(job.path);
            self.allocator.destroy(job);
        };
    }

    fn pollReloadJobs(self: *Workbench) bool {
        var changed = false;
        var index = self.reload_jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.reload_jobs.items[index];
            if (!job.done.load(.acquire)) continue;
            const result = job.future.await(self.async_io);
            _ = self.reload_jobs.orderedRemove(index);
            switch (result) {
                .content => |content_value| {
                    var content = content_value;
                    defer content.deinit(self.allocator);
                    if (self.findOpenInput(job.path)) |input| {
                        if (input.editor.isDirty()) {
                            input.editor.markConflict();
                        } else {
                            input.editor.applyReloadedContent(&content) catch {};
                        }
                        changed = true;
                    }
                },
                .err => {},
            }
            self.allocator.free(job.path);
            self.allocator.destroy(job);
        }
        return changed;
    }

    fn cancelReloadJobs(self: *Workbench) void {
        for (self.reload_jobs.items) |job| {
            const result = job.future.cancel(self.async_io);
            if (result == .content) {
                var content = result.content;
                content.deinit(self.allocator);
            }
            self.allocator.free(job.path);
            self.allocator.destroy(job);
        }
        self.reload_jobs.clearRetainingCapacity();
    }

    fn freeOpenOutcome(self: *Workbench, outcome: OpenOutcome) void {
        switch (outcome) {
            .text => |value| {
                var loaded = value;
                loaded.deinit(self.allocator);
            },
            .err => {},
        }
    }

    fn openLoadedTextEditor(self: *Workbench, path: []const u8, loaded: *const editor_widget.LoadedText, options: OpenOptions) !void {
        const editor = try Editor.createWithExtensionsFromLoadedText(
            self.allocator,
            self.io,
            loaded,
            path,
            self.cols,
            self.editorContentHeight(),
            self.declarative,
            self.json_client,
            .{ .reserve_scrollbar = true },
        );
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
        tab.setImageRuntime(&self.images);
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

    /// Drains completed async reads on the TUI thread. Returns true when a
    /// result was applied and a repaint is needed.
    pub fn pollAsyncReads(self: *Workbench) bool {
        var changed = false;
        if (self.pending_open) |job| {
            if (job.done.load(.acquire)) {
                const outcome = job.future.await(self.async_io);
                self.pending_open = null;
                const path = job.path;
                const options = job.options;
                const generation = job.generation;
                self.allocator.destroy(job);
                defer self.allocator.free(path);
                if (generation != self.open_generation) {
                    self.freeOpenOutcome(outcome);
                    return true;
                }
                switch (outcome) {
                    .text => |value| {
                        var loaded = value;
                        defer loaded.deinit(self.allocator);
                        self.recordNavigation();
                        self.openLoadedTextEditor(path, &loaded, options) catch |err| {
                            self.setStatusHint("Open failed: {s}", .{@errorName(err)});
                            return true;
                        };
                        self.clearStatusHint();
                    },
                    .err => |err| self.setStatusHint("Open failed: {s}", .{@errorName(err)}),
                }
                changed = true;
            }
        }
        if (self.pollImagePreviews()) changed = true;
        if (self.pollThemeJob()) changed = true;
        if (self.pollKeybindingsJob()) changed = true;
        return changed;
    }

    fn pollImagePreviews(self: *Workbench) bool {
        var changed = false;
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.image_preview) |preview| {
                    if (preview.poll()) changed = true;
                }
            }
        }
        return changed;
    }

    fn hasPendingImageLoads(self: *const Workbench) bool {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.image_preview) |preview| {
                    if (preview.hasPendingLoad()) return true;
                }
            }
        }
        return false;
    }

    /// True while a short read is in flight. The main loop clamps its input
    /// poll timeout so the result is applied promptly without busy-spinning
    /// the idle maintenance work.
    pub fn hasLatencySensitiveReads(self: *Workbench) bool {
        if (self.pending_open != null or self.reload_jobs.items.len != 0 or self.theme_job != null or
            self.keybindings_job != null or self.hasPendingImageLoads()) return true;
        if (self.sidebar) |sidebar| {
            if (sidebar.hasPendingLoad()) return true;
        }
        if (self.activeTab()) |tab| {
            if (tab.markdown_preview) |preview| {
                if (preview.hasPendingLocalImages()) return true;
            }
        }
        return false;
    }

    fn setStatusHint(self: *Workbench, comptime fmt: []const u8, args: anytype) void {
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
        self.cancelThemeJob();
        self.cancelKeybindingsJob();
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
            if (self.breadcrumbs_input == tab.editorInput()) self.disposeBreadcrumbs();
            self.unregisterWorkingCopy(tab);
            if (self.quick_diff_controller) |controller| controller.detach(tab.editor);
            self.detachHistoryTab(tab);
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
        self.hidePanel();
    }

    /// Close every editor in every group, stopping at the first dirty-close
    /// confirmation instead of silently discarding the remaining editors.
    pub fn closeAllEditors(self: *Workbench) !void {
        self.beginClosedBatch();
        defer self.endClosedBatch();
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
        self.beginClosedBatch();
        defer self.endClosedBatch();
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
            try self.setSidebarWidth(@intCast(next));
        }
        if (height_delta != 0 and self.panelShown()) {
            const current: isize = @intCast(self.panel_part.getSize());
            const min_height: isize = @intCast(panel_part_mod.title_height + 1);
            const next = @min(@max(current - height_delta, min_height), @as(isize, @intCast(@max(self.rows / 2, 3))));
            try self.panel_part.setSize(@intCast(next));
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
        // Moving the last active tab leaves the model without an active editor
        // even when the group still has tabs; activate one so the group keeps
        // its breadcrumb/editor chrome.
        if (source.activeTab() == null and source.tabs.items.len > 0) {
            try source.activateTab(source.tabs.items[0]);
        }
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

    /// Closes the active tab without the dirty confirmation. `:q!` uses this;
    /// all other close paths keep the confirmation.
    pub fn forceCloseActive(self: *Workbench) !void {
        self.part.active_sash = null;
        self.clearTabDrag();
        const pane = self.activePane() orelse return;
        const tab = pane.activeTab() orelse return;
        try self.performCloseTab(pane, tab);
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
    fn dialogTheme(self: *Workbench) ui.DialogTheme {
        return .{
            .background = self.themeColor("dialog.background", .{ 0x25, 0x25, 0x26 }),
            .border = self.themeColor("dialog.border", .{ 0x58, 0x58, 0x5A }),
            .text = self.themeColor("foreground", .{ 0xEB, 0xEB, 0xEB }),
            .detail = self.themeColor("descriptionForeground", .{ 0xC4, 0xC4, 0xC4 }),
            .warning = self.themeColor("editorWarning.foreground", .{ 0xE8, 0xC2, 0x5A }),
            .primary_background = self.themeColor("button.background", .{ 0x0E, 0x63, 0x9C }),
            .primary_focused_background = self.themeColor("button.hoverBackground", .{ 0x11, 0x77, 0xBB }),
            .primary_foreground = self.themeColor("button.foreground", .{ 0xFF, 0xFF, 0xFF }),
            .secondary_background = self.themeColor("button.secondaryBackground", .{ 0x3A, 0x3D, 0x41 }),
            .secondary_focused_background = self.themeColor("button.secondaryHoverBackground", .{ 0x45, 0x49, 0x4E }),
            .secondary_foreground = self.themeColor("button.secondaryForeground", .{ 0xFF, 0xFF, 0xFF }),
        };
    }

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
        dialog.theme = self.dialogTheme();

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
        self.pointer = .default;
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
        dialog.theme = self.dialogTheme();

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
        self.pointer = .default;
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

    fn beginClosedBatch(self: *Workbench) void {
        if (self.in_closed_batch) return;
        self.in_closed_batch = true;
        self.history.closed_batch_id +%= 1;
    }

    fn endClosedBatch(self: *Workbench) void {
        self.in_closed_batch = false;
    }

    pub fn reopenLastClosedEditor(self: *Workbench) bool {
        if (self.history.closed_editors.items.len == 0) return false;
        const batch_id = self.history.closed_editors.items[self.history.closed_editors.items.len - 1].batch_id;
        var reopened = false;
        while (self.history.closed_editors.items.len > 0) {
            const last = self.history.closed_editors.items[self.history.closed_editors.items.len - 1];
            if (last.batch_id != batch_id) break;
            const closed = self.history.closed_editors.pop().?;
            defer self.allocator.free(closed.path);
            self.openPath(closed.path) catch continue;
            if (self.activePane()) |pane| {
                if (pane.activeTab()) |tab| {
                    if (closed.index < pane.tabs.items.len) {
                        _ = pane.group.model.moveEditor(tab.input, @intCast(closed.index)) catch {};
                    }
                    if (closed.pinned) _ = pane.group.model.pin(tab.input) catch {};
                }
            }
            reopened = true;
        }
        return reopened;
    }

    fn performCloseTab(self: *Workbench, pane: *GroupPane, tab: *Tab) !void {
        if (!self.in_closed_batch) self.history.closed_batch_id +%= 1;
        if (pane.indexOfTab(tab)) |index| {
            self.history.recordClosedEditor(.{
                .path = self.allocator.dupe(u8, tab.editor.path) catch &.{},
                .group_id = pane.group.id,
                .index = index,
                .sticky = pane.group.model.isSticky(.{ .editor = tab.input }),
                .pinned = pane.group.model.isPinned(.{ .editor = tab.input }),
                .batch_id = self.history.closed_batch_id,
            }) catch {};
        }
        _ = try pane.group.model.closeEditor(tab.input, .UNKNOWN, true);
        _ = pane.removeTab(tab);
        pane.syncActivePane();
        if (self.breadcrumbs_input == tab.editorInput()) self.disposeBreadcrumbs();
        if (self.hovered_tab == tab) self.hovered_tab = null;
        if (!tab.isImage()) {
            self.unregisterWorkingCopy(tab);
            if (self.quick_diff_controller) |controller| controller.detach(tab.editor);
        }
        self.detachHistoryTab(tab);
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
            .panel_focus = try service.createKey("panelFocus", .{ .boolean = false }),
            .panel_visible = try service.createKey("panelVisible", .{ .boolean = false }),
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
        keys.panel_focus.set(.{ .boolean = (self.focus == .terminal or self.focus == .problems) and self.panelShown() });
        keys.panel_visible.set(.{ .boolean = self.panelShown() });
        keys.active_panel.set(.{ .string = if (self.panelShown()) self.activePanelId() else "" });
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
        self.disposeKeybindingServices();
        self.ensureUserKeybindings() catch {};
        self.applyKeybindingConsumers();
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
        self.freeUserOverrides(self.global_user_overrides);
        self.global_user_overrides = &.{};
        if (self.user_keybindings) |bindings| {
            bindings.deinit();
            self.user_keybindings = null;
        }
    }

    fn applyKeybindingConsumers(self: *Workbench) void {
        const removals = self.userRemovalOverrides();
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.isDiff()) tab.editor.reloadShortcutKeybindings(removals);
            }
        }
        if (self.search_view) |view| view.reloadKeybindings(removals);
    }

    /// Watcher-triggered keybindings reload. The JSONC files are read/parsed on
    /// the async Io, then installed on the TUI thread.
    fn requestKeybindingsReload(self: *Workbench) void {
        if (self.keybindings_job != null) {
            self.keybindings_reload_pending = true;
            return;
        }
        const paths = self.allocator.alloc([]u8, self.keybindings_paths.len) catch return;
        var initialized: usize = 0;
        for (self.keybindings_paths, 0..) |path, index| {
            paths[index] = self.allocator.dupe(u8, path) catch {
                for (paths[0..initialized]) |owned| self.allocator.free(owned);
                self.allocator.free(paths);
                return;
            };
            initialized += 1;
        }
        const job = self.allocator.create(KeybindingsJob) catch {
            for (paths) |path| self.allocator.free(path);
            self.allocator.free(paths);
            return;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.async_io,
            .future = undefined,
            .paths = paths,
        };
        job.future = self.async_io.async(runKeybindingsJob, .{job});
        self.keybindings_job = job;
    }

    fn pollKeybindingsJob(self: *Workbench) bool {
        const job = self.keybindings_job orelse return false;
        if (!job.done.load(.acquire)) return false;
        const result = job.future.await(self.async_io);
        self.keybindings_job = null;
        switch (result) {
            .bindings => |bindings| {
                self.disposeKeybindingServices();
                self.user_keybindings = bindings;
                self.applyKeybindingConsumers();
            },
            .err => {},
        }
        job.deinit(self.allocator);
        if (self.keybindings_reload_pending) {
            self.keybindings_reload_pending = false;
            self.requestKeybindingsReload();
        }
        return true;
    }

    fn cancelKeybindingsJob(self: *Workbench) void {
        self.keybindings_reload_pending = false;
        const job = self.keybindings_job orelse return;
        self.keybindings_job = null;
        const result = job.future.cancel(job.io);
        if (result == .bindings) {
            result.bindings.deinit();
        }
        job.deinit(self.allocator);
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

        self.finishThemeApply(loaded);
    }

    /// Watcher-triggered variant: resolves the same candidate sequence as
    /// `applyThemeSettings`, loads the selected theme on the async Io and
    /// installs it from `pollThemeJob`. Mirrors upstream's asynchronous
    /// `workbenchThemeService` reload.
    pub fn applyThemeSettingsAsync(self: *Workbench) void {
        self.ensureConfiguration() catch {};
        const configuration = self.configuration orelse return;
        const service = self.ensureThemeService() catch return;

        self.cancelThemeJob();
        const theme_configuration = theme_configuration_mod.ThemeConfiguration.init(
            configuration.interface(),
            self.theme_scheme_host.interface(),
        );
        const requested = theme_configuration.getColorTheme() orelse
            theme_service_mod.ThemeSettingDefaults.COLOR_THEME_DARK;
        const values = [_][]const u8{
            requested,
            theme_service_mod.ThemeSettingDefaults.COLOR_THEME_DARK,
            "vs-dark",
        };
        var count: usize = 0;
        for (values) |value| {
            const id = service.findThemeSettingsId(value) orelse continue;
            if (count >= self.theme_candidates.len) break;
            var duplicate = false;
            for (self.theme_candidates[0..count]) |existing| {
                if (existing) |candidate| {
                    if (std.mem.eql(u8, candidate, id)) duplicate = true;
                }
            }
            if (duplicate) continue;
            const copy = self.allocator.dupe(u8, id) catch continue;
            self.theme_candidates[count] = copy;
            count += 1;
        }
        self.theme_candidate_index = 0;
        self.startThemeCandidate();
    }

    fn startThemeCandidate(self: *Workbench) void {
        const service = self.theme_service orelse return;
        while (self.theme_candidate_index < self.theme_candidates.len) {
            const maybe_id = self.theme_candidates[self.theme_candidate_index];
            self.theme_candidate_index += 1;
            const id = maybe_id orelse continue;
            var request = theme_service_mod.ThemeService.PrepareRequest.init(service, id, self.allocator) catch continue;
            const job = self.allocator.create(ThemeLoadJob) catch {
                request.deinit();
                continue;
            };
            job.* = .{
                .allocator = self.allocator,
                .io = self.async_io,
                .service = service,
                .future = undefined,
                .request = request,
            };
            job.future = self.async_io.async(runThemeLoadJob, .{job});
            self.theme_job = job;
            return;
        }
        self.freeThemeCandidates();
        self.finishThemeApply(false);
    }

    /// Drains a completed theme load and installs it on the TUI thread.
    fn pollThemeJob(self: *Workbench) bool {
        const job = self.theme_job orelse return false;
        if (!job.done.load(.acquire)) return false;
        const result = job.future.await(self.async_io);
        self.theme_job = null;
        const service = self.theme_service orelse return false;
        switch (result) {
            .theme => |theme_value| {
                var theme = theme_value;
                var applied = true;
                service.applyPreparedTheme(job.request.id, theme) catch {
                    applied = false;
                    theme.deinit();
                };
                job.request.deinit();
                self.allocator.destroy(job);
                self.freeThemeCandidates();
                self.finishThemeApply(applied);
                return true;
            },
            .err => {
                job.request.deinit();
                self.allocator.destroy(job);
                self.startThemeCandidate();
                return true;
            },
        }
    }

    fn cancelThemeJob(self: *Workbench) void {
        if (self.theme_job) |job| {
            self.theme_job = null;
            const result = job.future.cancel(job.io);
            switch (result) {
                .theme => |theme_value| {
                    var theme = theme_value;
                    theme.deinit();
                },
                .err => {},
            }
            job.request.deinit();
            self.allocator.destroy(job);
        }
        self.freeThemeCandidates();
        self.theme_candidate_index = 0;
    }

    fn freeThemeCandidates(self: *Workbench) void {
        for (&self.theme_candidates) |*maybe_id| {
            if (maybe_id.*) |id| {
                self.allocator.free(id);
                maybe_id.* = null;
            }
        }
    }

    fn finishThemeApply(self: *Workbench, loaded: bool) void {
        const configuration = self.configuration orelse return;
        const service = self.theme_service orelse return;

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
        var inactive_it = self.breadcrumbs_inactive.iterator();
        while (inactive_it.next()) |entry| entry.value_ptr.*.control.setThemeColors(palette);
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
        if (self.handleSidebarResizeMouse(event)) return true;
        if (self.part.active_sash) |split| {
            switch (event.kind) {
                .move => {
                    // Upstream's sash owns pointer capture, so motion while
                    // the boundary is grabbed resizes it. Some terminals and
                    // multiplexers report that motion without the held button
                    // bits; relying on them here would drop the drag. A lost
                    // release is healed by the next down or up event.
                    self.part.resizeSash(split, event.x, event.y);
                    self.pointer = self.part.sashPointer(split);
                    return true;
                },
                .up, .click => {
                    self.part.resizeSash(split, event.x, event.y);
                    self.part.active_sash = null;
                    self.pointer = if (self.part.dividerAt(event.x, event.y)) |still_over|
                        self.part.sashPointer(still_over)
                    else
                        .default;
                    return true;
                },
                .down => {
                    self.pointer = self.part.sashPointer(split);
                    return true;
                },
                .wheel => return false,
            }
        }

        if (self.quick_access.isOpen()) return false;
        if (event.kind != .down or event.button != .left) {
            // Keep the editor from treating a click on the sash as a caret
            // placement; hover motion over the line is also consumed.
            if (self.sidebarShown() and
                event.x == self.activityBarWidth() + self.sidebarWidth() and
                event.y < self.workbenchRows())
            {
                self.pointer = .ew_resize;
                return true;
            }
            if (event.kind != .wheel) {
                if (self.part.dividerAt(event.x, event.y)) |split| {
                    self.pointer = self.part.sashPointer(split);
                    return true;
                }
            }
            return false;
        }

        const split = self.part.dividerAt(event.x, event.y) orelse return false;
        self.pointer = self.part.sashPointer(split);
        self.part.active_sash = split;
        return true;
    }

    /// Port of the side-bar splitter drag from `sidebarPart.ts`/`resizable.ts`.
    /// The divider is the one-cell border between the side bar and the editor
    /// area; a press captures the pointer, motion resizes with the upstream
    /// min/max clamps, and the release ends the gesture.
    fn handleSidebarResizeMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (self.quick_access.isOpen()) return false;
        if (!self.sidebarShown()) {
            self.sidebar_resize_active = false;
            return false;
        }

        const divider = self.activityBarWidth() + self.sidebarWidth();
        if (!self.sidebar_resize_active) {
            if (event.kind != .down or event.button != .left or event.x != divider) return false;
            self.sidebar_resize_active = true;
            self.pointer = .ew_resize;
            return true;
        }

        switch (event.kind) {
            .move, .down => {
                self.pointer = .ew_resize;
                self.resizeSidebarTo(event.x);
                return true;
            },
            .up, .click => {
                self.pointer = .ew_resize;
                self.resizeSidebarTo(event.x);
                self.sidebar_resize_active = false;
                return true;
            },
            .wheel => return false,
        }
    }

    fn resizeSidebarTo(self: *Workbench, pointer_x: usize) void {
        const bar_width = self.activityBarWidth();
        const desired = if (pointer_x > bar_width) pointer_x - bar_width else 1;
        const max_width = @max(self.cols / 2, 10);
        const width = std.math.clamp(desired, 10, max_width);
        if (width == self.sidebarWidth() and self.layout_model.size(.sidebar) == width) return;
        self.setSidebarWidth(width) catch return;
        self.layoutAll();
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
            .move => {
                self.pointer = .grabbing;
                self.updateDragTarget(event);
            },
            .up => {
                self.pointer = .default;
                self.finishTabDrag();
                return true;
            },
            .click => {
                self.pointer = .default;
                self.clearTabDrag();
                return true;
            },
            .down => {
                // A second press during a pending drag is often the second
                // half of a double click (hand jitter starts the drag). Let
                // the tab strip handle it so the preview can be pinned.
                self.pointer = .default;
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
        self.drag_tab_drop = null;
    }

    fn updateDragTarget(self: *Workbench, event: *const ui.MouseEvent) void {
        self.drag_target = null;
        self.drag_tab_drop = null;
        const pane = self.paneAt(event.x, event.y) orelse return;
        if (event.y == ui.cell.snap(pane.rect.y)) {
            self.drag_tab_drop = .{
                .pane = pane,
                .index = tab_bar.dropIndexAt(pane.hits.items, event.x, pane.tabs.items.len),
            };
            return;
        }
        const zone = editor_drop_target.zoneAt(pane.rect, event.x, event.y) orelse return;
        self.drag_target = .{ .pane = pane, .zone = zone };
    }

    fn finishTabDrag(self: *Workbench) void {
        const tab = self.drag_tab;
        const source = self.drag_source_pane;
        const target = self.drag_target;
        const strip_target = self.drag_tab_drop;
        self.clearTabDrag();
        if (tab == null or source == null) return;
        if (strip_target) |drop| {
            self.dropTabOnTabBar(source.?, tab.?, drop.pane, drop.index) catch |err| {
                if (self.activeTab()) |active| {
                    active.editor.setMessage("tile: {s}", .{@errorName(err)});
                }
            };
            return;
        }
        const pane_target = target orelse return;
        self.dropTab(source.?, tab.?, pane_target.pane, pane_target.zone) catch |err| {
            if (self.activeTab()) |active| {
                active.editor.setMessage("tile: {s}", .{@errorName(err)});
            }
        };
    }

    fn moveTabToPane(self: *Workbench, source: *GroupPane, dest: *GroupPane, tab: *Tab, index: ?isize) !void {
        _ = try source.group.model.closeEditor(tab.input, .MOVE, false);
        _ = source.removeTab(tab);
        source.syncActivePane();
        // Moving the last active tab leaves the model without an active editor
        // even when the group still has tabs; activate one so the group keeps
        // its breadcrumb/editor chrome.
        if (source.activeTab() == null and source.tabs.items.len > 0) {
            try source.activateTab(source.tabs.items[0]);
        }
        _ = try dest.group.model.openEditor(tab.input, .{ .pinned = true, .active = true, .index = index });
        try dest.addTab(tab);
        self.service.activateGroup(dest.group);
        try tab.ensureControllers();
        tab.focusEditor();
        self.focus = .editor;
    }

    /// Port of the tab-strip branches of upstream `MultiEditorTabsControl.onDrop`:
    /// a same-group drop reorders with upstream's target-index decrement, and a
    /// drop on another strip inserts at the previewed index.
    fn dropTabOnTabBar(self: *Workbench, source: *GroupPane, tab: *Tab, target: *GroupPane, index: usize) !void {
        if (source == target) {
            const from = target.group.model.indexOf(.{ .input = tab.input }) orelse return;
            var to = index;
            if (from < to) to -= 1;
            if (to == from) return;
            _ = try target.group.model.moveEditor(tab.input, @intCast(to));
            target.syncActivePane();
            self.service.activateGroup(target.group);
            self.focus = .editor;
            tab.focusEditor();
            return;
        }
        // The target group may already show this input; moving would create a
        // second Tab for one model.
        if (target.tabForInput(tab.input) != null) return;
        try self.moveTabToPane(source, target, tab, @intCast(index));
        self.collapseEmptyPane(source);
        self.layoutAll();
    }

    fn dropTab(self: *Workbench, source: *GroupPane, tab: *Tab, target: *GroupPane, zone: DropZone) !void {
        if (zone == .center) {
            if (source == target) return;
            // The target group may already show this input; moving would
            // create a second Tab for one model.
            if (target.tabForInput(tab.input) != null) return;
            try self.moveTabToPane(source, target, tab, null);
            self.collapseEmptyPane(source);
            self.layoutAll();
            return;
        }

        const direction: SplitDirection = editor_drop_target.orientation(zone);
        const new_first = editor_drop_target.newFirst(zone);

        // Insert before collapsing the source: if source and target are
        // siblings, collapsing first would promote and destroy the target leaf.
        const new_pane = try self.part.splitGroup(target, direction, new_first);
        try self.moveTabToPane(source, new_pane, tab, null);

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
                self.pointer = part.pointerAt(event.x, event.y) catch .default;
                self.leaveEditorHover();
                return true;
            },
            .down => {
                self.leaveEditorHover();
                if (event.button == .right) {
                    if (part.hitAt(event.x, event.y) catch null) |hit| {
                        switch (hit) {
                            .entry => |handle| {
                                part.setHovered(handle);
                                self.showStatusbarContextMenu(handle) catch {};
                            },
                            .part => part.clearHover(),
                        }
                    }
                    return true;
                }
                part.clearHover();
                self.focusStatusBar();
                self.pointer = part.pointerAt(event.x, event.y) catch .default;
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
            .up, .click => {
                self.pointer = part.pointerAt(event.x, event.y) catch .default;
                return true;
            },
            .wheel => return true,
        }
    }

    /// A click on the leading ellipsis lists the tabs clipped out of the strip
    /// and activates the chosen one.
    fn showTabOverflowMenu(self: *Workbench, pane: *GroupPane) !bool {
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try pane.orderedTabs(self.allocator, &ordered);
        if (pane.hits.items.len >= ordered.items.len) return false;
        _ = self.breadcrumbs_arena.reset(.retain_capacity);
        const arena = self.breadcrumbs_arena.allocator();

        var hidden = std.array_list.Managed(*Tab).init(self.allocator);
        errdefer hidden.deinit();
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
            hidden.deinit();
            return false;
        }

        var items = std.array_list.Managed(QuickPickItem).init(arena);
        for (hidden.items, 0..) |tab, index| {
            try items.append(.{ .item = .{
                .id = try std.fmt.allocPrint(arena, "overflow:{d}", .{index}),
                .label = tab.input.getName(),
            } });
        }
        if (self.tab_overflow_tabs) |old| self.allocator.free(old);
        self.tab_overflow_tabs = try hidden.toOwnedSlice();
        self.tab_menu_pane = pane;
        self.tab_menu_tab = null;
        try self.quick_access.inputService().showPick(
            items.items,
            .{ .placeholder = "Open Editor" },
            onTabOverflowPick,
            self,
        );
        return true;
    }

    /// Terminal form of the upstream tab context menu: close/close-others/
    /// close-all/pin actions presented through the quick pick.
    pub fn showTabContextMenu(self: *Workbench, pane: *GroupPane, tab: *Tab) !void {
        _ = self.breadcrumbs_arena.reset(.retain_capacity);
        const arena = self.breadcrumbs_arena.allocator();
        var items = std.array_list.Managed(QuickPickItem).init(arena);
        try items.append(.{ .item = .{ .id = "tab:close", .label = "Close" } });
        try items.append(.{ .item = .{ .id = "tab:close_others", .label = "Close Others" } });
        try items.append(.{ .item = .{ .id = "tab:close_right", .label = "Close to the Right" } });
        try items.append(.{ .item = .{ .id = "tab:close_saved", .label = "Close Saved" } });
        try items.append(.{ .item = .{ .id = "tab:close_all", .label = "Close All" } });
        const pinned = pane.group.model.isPinned(.{ .editor = tab.input });
        try items.append(.{ .item = .{
            .id = if (pinned) "tab:unpin" else "tab:pin",
            .label = if (pinned) "Unpin" else "Pin",
        } });
        try items.append(.{ .item = .{ .id = "tab:split_right", .label = "Split Right" } });
        try items.append(.{ .item = .{ .id = "tab:split_down", .label = "Split Down" } });
        self.tab_menu_pane = pane;
        self.tab_menu_tab = tab;
        try self.quick_access.inputService().showPick(
            items.items,
            .{ .placeholder = tab.input.getName() },
            onTabMenuPick,
            self,
        );
    }

    /// Terminal form of the upstream status-bar context menu: the hide and
    /// manage-extension actions are presented through the quick pick.
    pub fn showStatusbarContextMenu(self: *Workbench, handle: statusbar_model_mod.EntryHandle) !void {
        const entry = self.statusbar.main_part.model.findByHandle(handle) orelse return;
        _ = self.breadcrumbs_arena.reset(.retain_capacity);
        const arena = self.breadcrumbs_arena.allocator();
        var items = std.array_list.Managed(QuickPickItem).init(arena);
        try items.append(.{ .item = .{
            .id = try std.fmt.allocPrint(arena, "hide:{s}", .{entry.id}),
            .label = try std.fmt.allocPrint(arena, "Hide '{s}'", .{entry.item.name()}),
        } });
        if (entry.item.entry.extension_id != null) {
            try items.append(.{ .item = .{
                .id = try std.fmt.allocPrint(arena, "manage:{s}", .{entry.id}),
                .label = "Manage Extension",
            } });
        }
        try self.quick_access.inputService().showPick(
            items.items,
            .{ .placeholder = "Status Bar" },
            onStatusbarMenuPick,
            self,
        );
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
            // A focused sticky-scroll widget is the innermost focus target;
            // Escape leaves it before leaving the side bar (upstream leaves it
            // with Tab, which is the same terminal focus-traversal key).
            const active = self.activity_bar_part.active_id orelse "";
            if (std.mem.eql(u8, active, "explorer")) {
                if (self.sidebar) |sidebar| {
                    if (sidebar.tree.stickyScrollFocused()) {
                        sidebar.tree.clearStickyScrollFocus();
                        return true;
                    }
                }
            }
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
            if (self.scm_container) |container| {
                _ = container.handleKey(@constCast(event)) catch {};
            } else if (self.scm_view) |view| {
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
                self.requestOpenPath(path);
                self.focus = .editor;
                return true;
            },
            .handled, .none => return true,
        }
    }

    pub fn handleSidebarMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        // The activity bar stays clickable while the side bar is hidden; an
        // entry click reveals the side bar again, like upstream.
        if (event.x < self.activityBarWidth()) {
            if (event.kind == .wheel) return true;
            const activity_rect = self.activityRect();
            const hit = activity_bar_mod.hitAt(&self.activity_bar_part, event.x, event.y, activity_rect);
            self.pointer = if (hit != null) .pointer else .default;
            if (event.kind == .down) {
                if (activity_bar_mod.overflowHitAt(&self.activity_bar_part, event.x, event.y, activity_rect)) {
                    self.showActivityOverflowMenu() catch {};
                } else if (hit) |index| {
                    self.showActivity(index) catch {};
                }
            }
            return true;
        }

        if (!self.sidebarShown()) {
            if (event.kind == .move) {
                if (self.sidebar) |sidebar| sidebar.clearHover();
            }
            return false;
        }

        const sidebar_right = self.activityBarWidth() + self.sidebarWidth();
        if (event.x > sidebar_right) {
            if (event.kind == .move) {
                if (self.sidebar) |sidebar| sidebar.clearHover();
                if (self.scm_history_view) |view| view.clearHover();
            }
            return false;
        }

        // The side bar title chrome (header composite bar, title and footer):
        // title actions and the composite bar items only exist there, so the
        // rest of the side bar keeps routing events to its view.
        const rect = self.sidebarRect();
        const content = sidebar_part_mod.contentRect(&self.sidebar_part, rect);
        const content_top = ui.cell.snap(content.y);
        const content_height = ui.cell.snap(content.h);
        const in_chrome = content_height == 0 or
            event.y < content_top or
            event.y >= content_top + content_height;
        if (in_chrome) {
            if (event.kind == .move) {
                if (self.sidebar) |sidebar| sidebar.clearHover();
                const hit = sidebar_part_mod.hitTest(&self.sidebar_part, rect, event.x, event.y);
                sidebar_part_mod.setHovered(&self.sidebar_part, hit);
                self.pointer = if (hit != null) .pointer else .default;
                return true;
            }
            if (sidebar_part_mod.hitTest(&self.sidebar_part, rect, event.x, event.y)) |hit| {
                self.pointer = .pointer;
                if (event.kind == .down) switch (hit) {
                    .action => |id| self.runSidebarTitleAction(id),
                    .composite => |id| {
                        _ = self.showActivityById(id) catch {};
                    },
                };
                return true;
            }
            // A click on the chrome without an action only moves focus into
            // the part, like the browser title area.
            if (event.kind != .wheel) self.pointer = .default;
            if (event.kind == .down) self.focus = .sidebar;
            return true;
        }

        if (event.kind == .move) sidebar_part_mod.setHovered(&self.sidebar_part, null);
        if (event.kind == .down) self.focus = .sidebar;
        const active_id = self.activity_bar_part.active_id orelse "";
        if (std.mem.eql(u8, active_id, "scm")) {
            if (self.scm_container) |container| {
                if (container.hitTest(content, event.x, event.y)) |hit| {
                    // Mode-1003 terminals report idle motion. Only a press or
                    // click may run a title action or toggle a section; a move
                    // over a header just clears the list hover.
                    const activating = event.kind == .down or event.kind == .click;
                    switch (hit) {
                        .action => |action| {
                            if (activating) {
                                container.setActive(action.id);
                                self.runSidebarTitleAction(action.action);
                            }
                        },
                        .toggle => |id| {
                            if (activating) {
                                container.model.setCollapsed(id, !container.model.isCollapsed(id));
                                container.setActive(id);
                            }
                        },
                        .body => {
                            _ = container.handleMouse(@constCast(event), content) catch false;
                        },
                    }
                    if (event.kind == .move) {
                        switch (hit) {
                            .body => {},
                            else => {
                                if (self.scm_history_view) |view| view.clearHover();
                                if (self.scm_view) |view| view.clearHover();
                            },
                        }
                    }
                } else if (event.kind == .move) {
                    if (self.scm_history_view) |view| view.clearHover();
                    if (self.scm_view) |view| view.clearHover();
                }
            } else if (self.scm_view) |view| {
                _ = view.handleMouse(@constCast(event), content) catch false;
            }
            return true;
        }
        if (std.mem.eql(u8, active_id, "search")) {
            if (self.search_view) |view| _ = view.handleMouse(event);
            return true;
        }
        if (!std.mem.eql(u8, active_id, "explorer")) return true;

        const sidebar = self.sidebar orelse return false;
        if (event.kind == .move) {
            _ = sidebar.handleMouse(event);
            self.pointer = if (sidebar.hasHoveredRow()) .pointer else .default;
            return true;
        }
        if (event.kind == .wheel) {
            _ = sidebar.handleMouse(event);
            return true;
        }
        if (event.kind == .down) {
            if (sidebar.handleClickPreview(event.x, event.y) catch null) |path| {
                self.openPreviewPath(path) catch |err| {
                    // Like Enter and the async open path: report the failure
                    // instead of silently leaving the editor unchanged.
                    self.setStatusHint("Open failed: {s}", .{@errorName(err)});
                    return true;
                };
                self.focus = .editor;
            }
        }
        return true;
    }

    /// The panel title and the active panel view's input. Terminal content is
    /// left to `handleTerminalMouse` so the emulator keeps mouse reporting.
    pub fn handlePanelMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (!self.panelShown()) return false;
        const rect = self.panelRect();
        const rect_x = ui.cell.snap(rect.x);
        const rect_y = ui.cell.snap(rect.y);
        const rect_width = ui.cell.snap(rect.w);
        const rect_height = ui.cell.snap(rect.h);
        if (rect_width == 0 or rect_height == 0) return false;
        if (event.x < rect_x or event.x >= rect_x + rect_width) {
            self.panel_part.setHovered(null);
            return false;
        }
        if (event.y < rect_y or event.y >= rect_y + rect_height) {
            self.panel_part.setHovered(null);
            return false;
        }

        if (event.y == rect_y) {
            const hit = panel_part_mod.hitTest(&self.panel_part, rect, event.x, event.y);
            if (event.kind == .move) self.panel_part.setHovered(hit);
            if (event.kind != .wheel) self.pointer = if (hit != null) .pointer else .default;
            if (event.kind == .down and event.button == .left) {
                if (hit) |id| _ = self.openPanelContainer(id) catch {};
            }
            return true;
        }

        self.panel_part.setHovered(null);
        if (std.mem.eql(u8, self.activePanelId(), PROBLEMS_CONTAINER_ID)) {
            if (event.kind == .down) {
                self.focus = .problems;
                self.updateProblemsHighlight();
            }
            const content = panel_part_mod.contentRect(rect);
            if (self.problems_view) |view| _ = view.handleMouse(@constCast(event), content) catch false;
            return true;
        }
        return false;
    }

    /// Key routing for the Problems list in the panel. Terminal keys stay with
    /// `handleTerminalKey`.
    pub fn handlePanelKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
        if (!self.panelShown()) return false;
        if (self.focus != .problems) return false;
        if (!std.mem.eql(u8, self.activePanelId(), PROBLEMS_CONTAINER_ID)) return false;
        if (event.key == .escape) {
            self.focusEditor();
            if (self.activeTab()) |tab| tab.focusEditor();
            return true;
        }
        if (self.problems_view) |view| {
            _ = view.handleKey(@constCast(event)) catch {};
        }
        return true;
    }

    pub fn handleTabMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (event.x < self.editorAreaX()) return false;

        if (self.pending_tab_drag) |pending| {
            if (event.kind == .move and event.button == .left and
                (event.x -| pending.x) + (event.y -| pending.y) >= 3)
            {
                self.drag_tab = pending.tab;
                self.drag_source_pane = pending.pane;
                self.pending_tab_drag = null;
                self.updateDragTarget(event);
                self.pointer = .grabbing;
                return true;
            }
            if (event.kind == .up or event.kind == .click) self.pending_tab_drag = null;
        }

        const pane = self.paneAt(event.x, event.y) orelse {
            self.clearTabHover();
            return false;
        };
        const pane_y = ui.cell.snap(pane.rect.y);
        const breadcrumb_y = pane_y + pane.titleHeight();

        // Hover tracking on the tab row and the breadcrumb row.
        if (event.kind == .move) {
            if (pane.tabs_visible and event.y == pane_y) {
                self.hovered_pane = pane;
                if (pane.title_action_hit) |hit| {
                    if (event.x >= hit.start and event.x < hit.end) {
                        self.hovered_title_action_pane = pane;
                        self.hovered_tab = null;
                        self.pointer = .pointer;
                        return true;
                    }
                }
                self.hovered_title_action_pane = null;
                if (tab_bar.hitAt(pane.hits.items, event.x)) |index| {
                    self.hovered_tab = self.orderedTabAt(pane, index);
                    self.pointer = .pointer;
                } else {
                    self.hovered_tab = null;
                    self.pointer = .default;
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
            if (pane.tabs_visible and event.y == pane_y) {
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

        if (!pane.tabs_visible or event.y != pane_y) {
            if (pane.tabs.items.len > 0 and event.kind == .down and pane.tabs_visible) {
                self.service.activateGroup(pane.group);
            }
            return false;
        }

        // Every non-move event on the tab row resolves the shape here, before
        // the click paths below return early.
        {
            const over_action = if (pane.title_action_hit) |action_hit|
                event.x >= action_hit.start and event.x < action_hit.end
            else
                false;
            self.pointer = if (over_action or tab_bar.hitAt(pane.hits.items, event.x) != null)
                .pointer
            else
                .default;
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
            if (event.button == .right) {
                if (tab_bar.hitAt(pane.hits.items, event.x)) |index| {
                    if (self.orderedTabAt(pane, index)) |tab| {
                        self.showTabContextMenu(pane, tab) catch {};
                    }
                }
                return true;
            }
            if (event.button != .left) return false;
            if (pane.hits.items.len > 0 and event.x < pane.hits.items[0].start) {
                if (self.showTabOverflowMenu(pane) catch false) return true;
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
        if (event.x < self.editorAreaX()) return null;
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
    /// The terminal boundary for upstream editor focus/blur: only the active
    /// tab of the active group receives focus while the editor owns focus.
    fn syncEditorFocus(self: *Workbench) void {
        const active_pane = self.activePane();
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                const desired = self.focus == .editor and
                    pane == active_pane and pane.activeTab() == tab;
                if (tab.view.isFocused() != desired) _ = tab.view.setFocused(desired);
            }
        }
    }

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
        if (self.activeTab()) |tab| {
            if (tab.isImage()) {
                if (self.editor_status) |status| status.update(null) catch {};
                if (self.media_status) |status| status.update(tab.imageStatusInfo());
                return;
            }
        }
        const target = if (self.activeTab()) |tab| tab.editor.statusTarget() else null;
        if (self.editor_status) |status| {
            status.update(target) catch {};
        }
        if (self.media_status) |status| status.update(null);
    }

    fn renderScmHistoryHover(self: *Workbench) !void {
        const view = self.scm_history_view orelse return;
        const content = view.hoverContent() orelse return;
        const rect = view.hoverRect() orelse return;
        const x = self.activityBarWidth() + self.sidebarWidth() + 1;
        if (x >= self.cols) return;
        const max_width = self.cols - x - 1;
        if (max_width < 12) return;
        var lines: usize = 1;
        for (content) |ch| {
            if (ch == '\n') lines += 1;
        }
        const max_height = self.workbenchRows() -| ui.cell.snap(rect.y) -| 2;
        if (max_height < scm_history_hover_chrome + 1) return;
        const size = scmHistoryHoverSize(max_width, max_height, lines);

        if (self.scm_hover_surface == null or self.scm_hover_surface.?.doc.cols != size.width or self.scm_hover_surface.?.doc.rows != size.height) {
            if (self.scm_hover_surface) |*surface| {
                try surface.resize(size.width, size.height);
            } else {
                self.scm_hover_surface = try ui.Surface.init(self.allocator, .{ .cols = size.width, .rows = size.height });
            }
        }
        const surface = &self.scm_hover_surface.?;
        var background = ui.Color{ .r = 37, .g = 37, .b = 38 };
        var foreground = ui.Color{ .r = 204, .g = 204, .b = 204 };
        var border = ui.Color{ .r = 69, .g = 69, .b = 69 };
        if (self.theme_palette) |palette| {
            background = palette.color("editorHoverWidget.background", .{ 37, 37, 38 });
            foreground = palette.color("editorHoverWidget.foreground", .{ 204, 204, 204 });
            border = palette.color("editorHoverWidget.border", .{ 69, 69, 69 });
        }
        try paintScmHistoryHover(surface, content, size, background, foreground, border);
        try self.frame.next.blit(surface.grid(), x, ui.cell.snap(rect.y), size.width, size.height);
    }

    pub fn render(self: *Workbench, writer: *std.Io.Writer) !void {
        if (self.pointer_shapes) try self.pointer_state.update(writer, self.pointer);
        self.syncSearchActivity();
        self.syncEditorFocus();
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

        // The activity bar is a part of its own: it stays visible when the
        // side bar is hidden (default location) and moves into the side bar
        // title area for the top/bottom locations.
        if (self.activityBarWidth() > 0) {
            activity_bar_mod.render(&self.activity_bar_part, &self.activity_service, &self.frame.next, self.activityRect(), self.activeActivity(), self.focus == .sidebar, self.theme_palette);
        }

        if (self.sidebarShown()) {
            const focused = self.focus == .sidebar;
            const rect = self.sidebarRect();

            // The side bar part paints its own title chrome and background;
            // the active view pane container renders into the content area
            // below the title, like upstream.
            var badge_texts: [8][24]u8 = undefined;
            var badges: [8]pane_composite_mod.Badge = undefined;
            try sidebar_part_mod.render(
                &self.sidebar_part,
                &self.frame.next,
                rect,
                self.theme_palette,
                self.sidebarBadges(&badge_texts, &badges),
            );
            const content = sidebar_part_mod.contentRect(&self.sidebar_part, rect);
            const active_id = self.activity_bar_part.active_id orelse "";
            if (std.mem.eql(u8, active_id, "explorer")) {
                if (self.sidebar) |sidebar| {
                    if (self.theme_palette) |palette| sidebar.setThemeColors(palette);
                    try sidebar.render(&self.frame.next, content, focused, .{
                        .show_header = false,
                        .cell_borders = self.part.cell_borders,
                    });
                } else {
                    self.renderPlaceholder(content, focused);
                }
            } else if (std.mem.eql(u8, active_id, "search")) {
                if (self.search_view) |view| {
                    if (self.theme_palette) |palette| view.setThemeColors(palette);
                    try view.render(&self.frame.next, content, .{ .show_header = false });
                } else {
                    self.renderPlaceholder(content, focused);
                }
            } else if (std.mem.eql(u8, active_id, "scm")) {
                if (self.scm_container) |container| {
                    try container.render(&self.frame.next, content, focused, self.theme_palette);
                } else if (self.scm_view) |view| {
                    if (self.theme_palette) |palette| view.setThemeColors(palette);
                    try view.render(&self.frame.next, content, focused, .{ .show_header = false });
                } else {
                    self.renderPlaceholder(content, focused);
                }
            } else {
                self.renderPlaceholder(content, focused);
            }

            // The border belongs to the side bar, so the divider cell keeps
            // the side bar background; an unset background would fall back to
            // the terminal's default background and read as a bright stripe.
            const divider_x = self.activityBarWidth() + self.sidebarWidth();
            const style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(self.themeColor("sideBar.border", .{ 70, 70, 70 })),
                .bg = ui.cell.packColor(self.themeColor("sideBar.background", .{ 30, 30, 33 })),
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
        if (self.panelShown()) {
            try self.renderPanel();
        }
        if (self.statusBarVisible()) {
            if (self.theme_palette) |palette| self.statusbar.main_part.setThemeColors(palette);
            try self.statusbar.main_part.render(&self.frame.next, self.statusBarRect(), .{
                .no_folder = self.workspace.getWorkbenchState() == .EMPTY,
                .part_focused = self.focus == .statusbar,
            });
        }
        try self.renderScmHistoryHover();
        try self.quick_access.render(&self.frame.next);
        if (self.dialog) |dialog| dialog.render(&self.frame.next);

        // Image uploads/placements must reach the terminal before the frame
        // body, in the same synchronized update, so a frame never shows
        // placeholder cells without their image data.
        const image_output = self.images.hasPending();
        if (image_output) try writer.writeAll("\x1b[?2026h");
        try self.images.flush(writer);
        const encoded = try ui.ansi.encode(
            self.allocator,
            if (self.frame.have_prev) &self.frame.prev else null,
            &self.frame.next,
            .{ .synchronized = !image_output },
        );
        defer self.allocator.free(encoded);
        if (encoded.len > 0) try writer.writeAll(encoded);
        if (image_output) try writer.writeAll("\x1b[?2026l");

        self.frame.swap();
    }

    /// Paints the panel title (composite bar) and the active container's
    /// content. The terminal keeps its own tab strip inside the content area,
    /// like the upstream panel's container hosting the terminal view.
    fn renderPanel(self: *Workbench) !void {
        const rect = self.panelRect();
        const focused = self.focus == .terminal or self.focus == .problems;
        var badge_buf: [48]u8 = undefined;
        var badges: [1]panel_part_mod.Badge = undefined;
        const badge_slice = self.panelBadges(&badge_buf, &badges);
        try panel_part_mod.renderTitle(
            &self.panel_part,
            &self.frame.next,
            rect,
            focused,
            self.theme_palette,
            badge_slice,
        );

        const content = panel_part_mod.contentRect(rect);
        const active_id = self.activePanelId();
        if (std.mem.eql(u8, active_id, TERMINAL_CONTAINER_ID)) {
            if (self.terminal_service) |service| {
                try terminal_panel.render(
                    &self.frame.next,
                    service,
                    content,
                    self.focus == .terminal,
                    self.theme_palette,
                );
            } else {
                self.renderPlaceholder(content, focused);
            }
        } else if (std.mem.eql(u8, active_id, PROBLEMS_CONTAINER_ID)) {
            if (self.problems_view) |view| {
                try view.render(&self.frame.next, content, self.focus == .problems, .{ .show_header = false });
            } else {
                self.renderPlaceholder(content, focused);
            }
        } else {
            self.renderPlaceholder(content, focused);
        }
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
        const label_format = self.editorLabelFormat();
        const close_button_visible = tabCloseButtonVisible(self.editorTabCloseButton());
        var descriptions = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (descriptions.items) |description| self.allocator.free(description);
            descriptions.deinit();
        }
        for (ordered.items, 0..) |tab, index| {
            infos[index] = .{
                .label = tab.input.getName(),
                .file_name = std.fs.path.basename(tab.editor.path),
                .dirty = tab.input.isDirty(),
                .pinned = pane.group.model.isPinned(.{ .editor = tab.input }),
                .sticky = pane.group.model.isSticky(.{ .editor = tab.input }),
                .closeable = close_button_visible and
                    !tab.input.hasCapability(editor_mod.EditorInputCapabilities.CannotClose),
            };
            var duplicate = false;
            for (ordered.items, 0..) |other, other_index| {
                if (other_index == index) continue;
                if (std.mem.eql(u8, other.input.getName(), tab.input.getName())) {
                    duplicate = true;
                    break;
                }
            }
            if (try self.tabDescription(tab.editor.path, duplicate, label_format)) |description| {
                infos[index].description = description;
                try descriptions.append(description);
            }
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
        var drop_index: ?usize = null;
        if (self.drag_tab_drop) |drop| {
            if (drop.pane == pane) drop_index = drop.index;
        }
        if (pane.titleHeight() > 0) {
            pane.title_action_hit = try tab_bar.draw(
                &self.frame.next,
                infos,
                pane.activeIndex(ordered.items),
                x,
                y,
                width,
                &pane.hits,
                .{
                    .group_active = active_group,
                    .hovered = hovered_index,
                    .close_button_left = std.mem.eql(u8, self.editorTabCloseButton(), "left"),
                    .tab_sizing = self.editorTabSizing(),
                    .title_action = title_action,
                    .drop_index = drop_index,
                    .cell_borders = self.part.cell_borders,
                },
                self.theme_palette,
            );
        } else {
            pane.title_action_hit = null;
            pane.hits.clearRetainingCapacity();
        }

        const chrome = pane.chromeHeight();
        if (chrome > height) return;
        if (chrome > pane.titleHeight()) {
            try self.renderBreadcrumbs(pane, x, y + pane.titleHeight(), width, active_group);
        }
        if (pane.activeTab()) |active| {
            if (active.controllers) |controllers| {
                controllers.find_add_extra_space = self.findAddExtraSpaceOnTop();
                const widget = controllers.find.widget();
                widget.setFindOnType(self.findOnType());
                widget.setCloseOnResult(self.findCloseOnResult());
                controllers.find.setSeedSearchStringFromSelection(self.findSeedSearchStringFromSelection());
                controllers.find.setAutoFindInSelection(self.findAutoFindInSelection());
                widget.setHistorySettings(
                    self.findHistoryEnabled("editor.find.history"),
                    self.findHistoryEnabled("editor.find.replaceHistory"),
                );
                controllers.find.state.loop = self.findLoop();
            }
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
        const title = if (std.mem.eql(u8, active_id, "scm"))
            "Source Control is unavailable (no Git repository)"
        else if (std.mem.eql(u8, active_id, "explorer") or std.mem.eql(u8, active_id, "search"))
            // Both views are created with the workspace file tree.
            "No folder is open"
        else
            "Nothing to show here";
        self.frame.next.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), bg);
        // The side bar title is painted by the part; the placeholder only
        // renders the container content.
        drawPlainText(&self.frame.next, x + 1, y, width -| 2, title, bg);
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

    /// First workspace folder resource, or null for an empty workspace.
    fn workspaceRoot(self: *const Workbench) ?[]const u8 {
        const folders = self.workspace.getWorkspace().folders.items;
        if (folders.len == 0) return null;
        return folders[0].resource;
    }

    /// Port of the `workbench.activityBar.location` / `.autoHide` /
    /// `.compact` configuration listener: the side bar part decides where its
    /// composite bar lives and whether the activity bar is shown at all.
    fn applyLayoutSettings(self: *Workbench) void {
        const values = layout_service_mod.LayoutSettingsValues.load(self.configuration, self.workspaceRoot());
        self.activity_bar_part.setCompact(values.activity_bar_compact) catch {};
        self.sidebar_part.setLayoutSettings(values) catch {};
        self.syncActivityBarVisibility() catch {};
        self.layoutAll();
    }

    /// Port of `SidebarPart.onDidChangeActivityBarLocation`: the rail is shown
    /// while the side bar does not host the composite bar.
    fn syncActivityBarVisibility(self: *Workbench) !void {
        const show = self.sidebar_part.shouldShowActivityBar();
        try self.activity_bar_part.setVisible(show);
        try self.layout_model.setVisible(.activitybar, show);
    }

    fn applyBreadcrumbsSettings(self: *Workbench) void {
        self.breadcrumbs_settings = BreadcrumbsSettings.load(self.configuration);
        if (self.breadcrumbs_control) |control| {
            control.setSettings(self.breadcrumbs_settings) catch {};
        }
        var it = self.breadcrumbs_inactive.iterator();
        while (it.next()) |entry| entry.value_ptr.*.control.setSettings(self.breadcrumbs_settings) catch {};
        if (!self.breadcrumbs_settings.enabled) {
            self.disposeBreadcrumbs();
            self.disposeAllInactiveBreadcrumbs();
        }
        self.layoutAll();
        self.breadcrumbs_dirty = true;
    }

    fn ensureBreadcrumbsControl(self: *Workbench, pane: *GroupPane) !*BreadcrumbsControl {
        const tab = pane.activeTab() orelse return error.NoActiveTab;
        if (tab.isImage()) return error.NoActiveTab;
        self.disposeInactiveBreadcrumbs(pane.group.id);
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
            self.homePath(),
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

    fn disposeInactiveBreadcrumbs(self: *Workbench, group: u32) void {
        if (self.breadcrumbs_inactive.fetchRemove(group)) |entry| {
            entry.value.registration.dispose();
            entry.value.control.deinit();
            self.allocator.destroy(entry.value);
        }
    }

    fn disposeAllInactiveBreadcrumbs(self: *Workbench) void {
        var it = self.breadcrumbs_inactive.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.registration.dispose();
            entry.value_ptr.*.control.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.breadcrumbs_inactive.deinit(self.allocator);
        self.breadcrumbs_inactive = .empty;
    }

    fn ensureInactiveBreadcrumbs(self: *Workbench, pane: *GroupPane) ?*BreadcrumbsControl {
        const tab = pane.activeTab() orelse return null;
        if (tab.isImage()) return null;
        if (self.breadcrumbs_inactive.get(pane.group.id)) |entry| {
            if (entry.pane == pane and entry.input == tab.editorInput()) return entry.control;
            self.disposeInactiveBreadcrumbs(pane.group.id);
        }

        const entry = self.allocator.create(InactiveBreadcrumb) catch return null;
        entry.pane = pane;
        entry.input = tab.editorInput();
        entry.context = .{ .workbench = self, .pane = pane };
        const control = BreadcrumbsControl.init(
            self.allocator,
            breadcrumbHost(&entry.context),
            self.workspace,
            self.configuration,
            &self.outline_service,
            self.homePath(),
        ) catch {
            self.allocator.destroy(entry);
            return null;
        };
        control.setGroup(pane.group.id);
        control.setThemeColors(self.theme_palette);
        const registration = self.breadcrumbs_service.register(pane.group.id, control) catch {
            control.deinit();
            self.allocator.destroy(entry);
            return null;
        };
        entry.control = control;
        entry.registration = registration;
        self.breadcrumbs_inactive.put(self.allocator, pane.group.id, entry) catch {
            registration.dispose();
            control.deinit();
            self.allocator.destroy(entry);
            return null;
        };
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

        // Inactive groups keep one persistent control each, so rendering the
        // group does not recreate its outline model every frame.
        const control = self.ensureInactiveBreadcrumbs(pane) orelse return;
        if (!std.meta.eql(control.settings, self.breadcrumbs_settings)) {
            control.setSettings(self.breadcrumbs_settings) catch {};
        }
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
        self.tab_menu_pane = null;
        self.tab_menu_tab = null;
        self.tab_overflow_tabs = null;
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
        const parent = breadcrumbs_picker.parentDirectory(directory);
        if (!std.mem.eql(u8, parent, directory)) {
            try items.append(.{ .item = .{
                .id = try std.fmt.allocPrint(arena, "u:{s}", .{parent}),
                .label = "..",
                .description = "parent folder",
            } });
        }
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
        self.requestOpenPath(path);
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
            const cursor = terminal_view.cursorCell(&instance.emulator, terminal_panel.contentRect(self.panelContentRect())) orelse return null;
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

    /// Resets the requested shape before one mouse-move is routed. Each
    /// handler that recognizes a target sets its own shape; anything that
    /// consumes the event without setting one leaves the terminal default.
    /// Presses and releases keep the shape the last move established.
    pub fn beginMousePointer(self: *Workbench) void {
        self.pointer = .default;
    }

    /// Resolves the pointer for the editor pane under a mouse cell. The tab
    /// strip and breadcrumb row are handled by `handleTabMouse` before this is
    /// reached, so only the pane content remains.
    pub fn updateMousePointer(self: *Workbench, event: ui.MouseEvent) void {
        const pane = self.paneAt(event.x, event.y) orelse {
            self.pointer = .default;
            return;
        };
        const pane_x = ui.cell.snap(pane.rect.x);
        const pane_y = ui.cell.snap(pane.rect.y);
        if (event.x < pane_x or event.y < pane_y + pane.chromeHeight()) {
            self.pointer = .default;
            return;
        }
        const tab = pane.activeTab() orelse {
            self.pointer = .default;
            return;
        };
        self.pointer = tab.pointerAt(
            event.x - pane_x,
            event.y - (pane_y + pane.chromeHeight()),
        ) catch .default;
    }

    /// Hosts call this after the kitty graphics probe (and when it changes).
    pub fn setImageProtocol(self: *Workbench, capability: ui.image.Capability) void {
        if (self.images.protocol == capability) return;
        self.images.setProtocol(capability);
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.isImage()) {
                    tab.invalidateImages();
                    continue;
                }
                if (tab.markdown_preview) |preview| {
                    preview.invalidateImages();
                    preview.forceRefresh() catch {};
                }
            }
        }
    }

    /// Terminal cell pixel size (from `TIOCGWINSZ`). Image row counts and the
    /// image-preview fit depend on it.
    pub fn setCellPixelSize(self: *Workbench, width_px: usize, height_px: usize) void {
        if (width_px == 0 or height_px == 0) return;
        if (width_px == self.images.cell_width_px and height_px == self.images.cell_height_px) return;
        self.images.setCellSize(width_px, height_px);
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.isImage()) {
                    tab.invalidateImages();
                    continue;
                }
                if (tab.markdown_preview) |preview| {
                    preview.invalidateImages();
                    preview.forceRefresh() catch {};
                }
            }
        }
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

const InactiveBreadcrumb = struct {
    control: *BreadcrumbsControl,
    context: BreadcrumbContext,
    registration: IDisposable,
    pane: *GroupPane,
    input: *EditorInput,
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
        .file_icon = breadcrumbFileIcon,
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

fn breadcrumbFileIcon(context: *anyopaque) ?file_icon.Icon {
    const self: *BreadcrumbContext = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return null;
    if (tab.editor.path.len == 0) return null;
    return file_icon.forPath(tab.editor.path);
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

fn onActivityOverflowPick(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const item = picker.activeItem() orelse return;
    if (!std.mem.startsWith(u8, item.id, "activity:")) return;
    _ = try self.showActivityById(item.id[9..]);
}

fn onTabOverflowPick(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const item = picker.activeItem() orelse return;
    const index = itemIndex(item.id, "overflow:") orelse return;
    const tabs = self.tab_overflow_tabs orelse return;
    self.tab_overflow_tabs = null;
    defer self.allocator.free(tabs);
    if (index >= tabs.len) return;
    const pane = self.tab_menu_pane orelse return;
    self.tab_menu_pane = null;
    try pane.activateTab(tabs[index]);
    self.focusEditor();
    self.layoutAll();
}

fn onTabMenuPick(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const item = picker.activeItem() orelse return;
    const pane = self.tab_menu_pane orelse return;
    const tab = self.tab_menu_tab orelse return;
    self.tab_menu_pane = null;
    self.tab_menu_tab = null;

    if (std.mem.eql(u8, item.id, "tab:close")) {
        _ = try self.closeTab(pane, tab);
    } else if (std.mem.eql(u8, item.id, "tab:close_others")) {
        const tabs = try self.breadcrumbs_arena.allocator().dupe(*Tab, pane.tabs.items);
        for (tabs) |candidate| {
            if (candidate == tab) continue;
            _ = try self.closeTab(pane, candidate);
            if (self.dialog != null) break;
        }
    } else if (std.mem.eql(u8, item.id, "tab:close_right")) {
        const index = pane.indexOfTab(tab) orelse return;
        const tabs = try self.breadcrumbs_arena.allocator().dupe(*Tab, pane.tabs.items);
        for (tabs, 0..) |candidate, candidate_index| {
            if (candidate_index <= index) continue;
            _ = try self.closeTab(pane, candidate);
            if (self.dialog != null) break;
        }
    } else if (std.mem.eql(u8, item.id, "tab:close_saved")) {
        const tabs = try self.breadcrumbs_arena.allocator().dupe(*Tab, pane.tabs.items);
        for (tabs) |candidate| {
            if (candidate.editor.isDirty()) continue;
            _ = try self.closeTab(pane, candidate);
            if (self.dialog != null) break;
        }
    } else if (std.mem.eql(u8, item.id, "tab:close_all")) {
        const tabs = try self.breadcrumbs_arena.allocator().dupe(*Tab, pane.tabs.items);
        for (tabs) |candidate| {
            _ = try self.closeTab(pane, candidate);
            if (self.dialog != null) break;
        }
    } else if (std.mem.eql(u8, item.id, "tab:pin")) {
        _ = pane.group.model.pin(tab.input) catch {};
        self.layoutAll();
    } else if (std.mem.eql(u8, item.id, "tab:unpin")) {
        _ = pane.group.model.unpin(tab.input) catch {};
        self.layoutAll();
    } else if (std.mem.eql(u8, item.id, "tab:split_right") or
        std.mem.eql(u8, item.id, "tab:split_down"))
    {
        try pane.activateTab(tab);
        self.focusEditor();
        try self.splitActive(if (std.mem.eql(u8, item.id, "tab:split_right"))
            .horizontal
        else
            .vertical);
    }
    self.breadcrumbs_dirty = true;
}

fn onStatusbarMenuPick(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const item = picker.activeItem() orelse return;
    if (std.mem.startsWith(u8, item.id, "hide:")) {
        self.statusbar.main_part.model.hide(item.id[5..]);
        return;
    }
    if (std.mem.startsWith(u8, item.id, "manage:")) {
        const entry = self.statusbar.main_part.model.findEntry(item.id[7..]) orelse return;
        if (entry.item.entry.extension_id) |extension_id| {
            if (self.statusbar.main_part.command_executor) |executor| {
                var action = statusbar_actions.ManageExtensionAction{
                    .extension_id = extension_id,
                    .executor = executor,
                };
                try action.run();
            }
        }
    }
}

fn onBreadcrumbPick(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const item = picker.activeItem() orelse return;
    const id = item.id;
    if (std.mem.startsWith(u8, id, "f:")) {
        try self.openBreadcrumbFile(id[2..]);
    } else if (std.mem.startsWith(u8, id, "d:")) {
        try self.showBreadcrumbPickerForDir(id[2..], null);
    } else if (std.mem.startsWith(u8, id, "u:")) {
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
    self.requestOpenPath(path);
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

fn commandTogglePanel(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.panelShown()) {
        self.hidePanel();
        return;
    }
    const id = self.defaultPanelContainerId() orelse return;
    _ = try self.openPanelContainer(id);
}

fn commandFocusPanel(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (!self.panelShown()) {
        const id = self.defaultPanelContainerId() orelse return;
        _ = try self.openPanelContainer(id);
        return;
    }
    if (std.mem.eql(u8, self.activePanelId(), PROBLEMS_CONTAINER_ID)) {
        self.focus = .problems;
    } else if (std.mem.eql(u8, self.activePanelId(), TERMINAL_CONTAINER_ID)) {
        self.focus = .terminal;
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
    if (self.scm_history_view) |view| {
        view.outdated = false;
        view.refresh(.reload) catch {};
    }
}

fn commandScmHistoryRefresh(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.scm_history_view) |view| {
        view.outdated = false;
        try view.refresh(.reload);
    }
}

fn commandScmHistoryPickRefs(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.showHistoryRefPicker();
}

fn commandScmHistoryReveal(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.scm_history_view) |view| try view.revealCurrentHistoryItem();
}

fn commandScmHistoryListMode(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.scm_history_view) |view| view.setViewMode(.list);
}

fn commandScmHistoryTreeMode(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.scm_history_view) |view| view.setViewMode(.tree);
}

fn commandScmListMode(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.scm_view) |view| view.setViewMode(.list);
}

fn commandScmTreeMode(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.scm_view) |view| view.setViewMode(.tree);
}

fn commandScmSortByName(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.scm_view) |view| view.setViewSortKey(.name);
}

fn commandScmSortByPath(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.scm_view) |view| view.setViewSortKey(.path);
}

fn commandScmSortByStatus(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (self.scm_view) |view| view.setViewSortKey(.status);
}

fn commandGitCommit(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const view = self.scm_view orelse return;
    _ = view.commitInput();
}

fn commandGitOpenChange(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const view = self.scm_view orelse return;
    const resource = view.selectedResource() orelse return;
    const provider = self.repository orelse return;
    const git_resource: *repository_mod.GitScmResource = @ptrCast(@alignCast(resource.context));
    try self.openScmChange(provider, git_resource);
}

fn commandGitOpenFile(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return;
    const diff = tab.diff orelse return;
    try self.openPath(diff.model.modified_path);
}

/// The SCM history hover is an `editorHoverWidget`: one cell of border plus
/// one cell of content padding on every side. `ui` `width`/`height` describe
/// the content box, so the allocated surface is the border box and the DOM
/// root stays four cells smaller; sizing the root to the surface clipped the
/// right and bottom edges.
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
    border: ui.Color,
) !void {
    const doc = surface.document();
    doc.clear();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = @floatFromInt(size.content_width) },
        .height = .{ .cells = @floatFromInt(size.content_height) },
        .background = background,
        .color = foreground,
        .border = .all(1),
        .border_color = border,
        .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
        .white_space = .pre,
        .overflow = .hidden,
    });
    _ = try root.appendText(content);
    doc.setRoot(root);
    try surface.paintFrame();
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
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.git_status_dirty = true;
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

fn commandCloseEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = try self.closeActive();
}

fn commandReopenClosedEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    _ = self.reopenLastClosedEditor();
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

fn commandImageZoomIn(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return;
    const pane = tab.image_preview orelse return;
    pane.zoomIn();
    self.refreshStatus();
}

fn commandImageZoomOut(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return;
    const pane = tab.image_preview orelse return;
    pane.zoomOut();
    self.refreshStatus();
}

const image_zoom_pick_items = [_]QuickPickItem{
    .{ .item = .{ .id = "10", .label = "1000%" } },
    .{ .item = .{ .id = "5", .label = "500%" } },
    .{ .item = .{ .id = "2", .label = "200%" } },
    .{ .item = .{ .id = "1", .label = "100%" } },
    .{ .item = .{ .id = "0.5", .label = "50%" } },
    .{ .item = .{ .id = "0.2", .label = "20%" } },
    .{ .item = .{ .id = "fit", .label = "Whole Image" } },
};

fn commandImageSelectZoomLevel(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return;
    const pane = tab.image_preview orelse return;
    const active_id = switch (pane.currentScale()) {
        .fit => "fit",
        .number => |value| blk: {
            if (value == 10) break :blk "10";
            if (value == 5) break :blk "5";
            if (value == 2) break :blk "2";
            if (value == 1) break :blk "1";
            if (value == 0.5) break :blk "0.5";
            if (value == 0.2) break :blk "0.2";
            break :blk "";
        },
    };
    try self.quick_access.inputService().showPick(
        &image_zoom_pick_items,
        .{ .placeholder = "Select zoom level", .active_id = if (active_id.len > 0) active_id else null },
        onImageZoomLevelAccepted,
        self,
    );
}

fn onImageZoomLevelAccepted(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    const tab = self.activeTab() orelse return;
    const pane = tab.image_preview orelse return;
    const item = picker.selectedItem() orelse return;
    if (std.mem.eql(u8, item.id, "fit")) {
        pane.setScale(.fit);
    } else {
        const value = std.fmt.parseFloat(f64, item.id) catch return;
        pane.setScale(.{ .number = value });
    }
    self.refreshStatus();
}

fn commandImageOpenInTextEditor(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    try self.openActiveImageAsText();
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

fn commandCloseSidebar(context: *anyopaque) anyerror!void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    if (!self.sidebar_part.isVisible()) return;
    try self.setSidebarVisible(false);
    self.focus = .editor;
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

fn searchOpenFiles(context: *anyopaque, allocator: Allocator) anyerror![][]u8 {
    const self: *Workbench = @ptrCast(@alignCast(context));
    var paths = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }
    for (self.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| {
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

test "Workbench: threaded tokenizer shuts down after tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "tokenized.zig", "const value = 1; // comment\n");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 10);
    defer workbench.deinit();
    workbench.enableAsyncTokenization();
    try std.testing.expect(workbench.textmate_background != null);
}

test "Workbench: sticky scroll paints scope headers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source = std.array_list.Managed(u8).init(allocator);
    defer source.deinit();
    try source.appendSlice("async function stickyScope() {\n");
    var line_buffer: [64]u8 = undefined;
    for (0..30) |index| {
        const line = try std.fmt.bufPrint(&line_buffer, "\tconst value{d} = {d};\n", .{ index, index });
        try source.appendSlice(line);
    }
    try source.appendSlice("}\n");

    const path = try seedFile(allocator, io, &tmp, "sticky.js", source.items);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 12);
    defer workbench.deinit();
    const tab = workbench.activeTab().?;
    try tab.ensureControllers();
    if (tab.controllers) |controllers| {
        _ = controllers.sticky.onTick(std.math.maxInt(i64));
    }
    _ = tab.editor.setTopViewLine(5);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const text = try frameText(allocator, &workbench.frame);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "async function stickyScope") != null);
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
    try std.testing.expectEqual(@as(usize, 0), tab.view.renderCount());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expectEqual(@as(usize, 1), tab.view.renderCount());
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

test "Workbench: tabs and editor content resolve pointer shapes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "pointer_shape.txt", "abc");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 50, 10);
    defer workbench.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    const tab_x = pane.hits.items[0].start;
    const title_y = ui.cell.snap(pane.rect.y);

    workbench.beginMousePointer();
    var over_tab = ui.MouseEvent{ .kind = .move, .x = tab_x, .y = title_y };
    try std.testing.expect(workbench.handleTabMouse(&over_tab));
    try std.testing.expectEqual(ui.Pointer.pointer, workbench.pointerShape());

    workbench.beginMousePointer();
    var empty_strip = over_tab;
    empty_strip.x = ui.cell.snap(pane.rect.right()) - 1;
    try std.testing.expect(workbench.handleTabMouse(&empty_strip));
    try std.testing.expectEqual(ui.Pointer.default, workbench.pointerShape());

    workbench.beginMousePointer();
    const content = ui.MouseEvent{
        .kind = .move,
        .x = ui.cell.snap(pane.rect.x) + tab.editor.gutterWidth() + 1,
        .y = title_y + pane.chromeHeight(),
    };
    workbench.updateMousePointer(content);
    try std.testing.expectEqual(ui.Pointer.text, workbench.pointerShape());
}

test "Workbench: render emits OSC 22 only when the pointer changes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "pointer_render.txt", "abc");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 8);
    defer workbench.deinit();
    workbench.setPointerShapes(true);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // The initial default shape adds no bytes to the first frame.
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;") == null);

    out.clearRetainingCapacity();
    workbench.setPointer(.pointer);
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;pointer\x1b\\") != null);

    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;") == null);

    out.clearRetainingCapacity();
    workbench.setPointer(.default);
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;default\x1b\\") != null);
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

test "Workbench: dragging over a tab strip previews the insertion and reorders on drop" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "strip_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "strip_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    workbench.setCellBorders(true);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    const tab_y = ui.cell.snap(pane.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = pane.hits.items[0].start, .y = tab_y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&down));

    // Right half of the second tab: insert after it, not a top-edge split.
    const second = pane.hits.items[1];
    var move = ui.MouseEvent{
        .kind = .move,
        .x = second.start + (second.end - second.start) / 2 + 1,
        .y = tab_y,
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&move));
    try std.testing.expect(workbench.drag_tab != null);
    try std.testing.expect(workbench.drag_target == null);
    try std.testing.expect(workbench.drag_tab_drop != null);
    try std.testing.expect(workbench.drag_tab_drop.?.pane == pane);
    try std.testing.expectEqual(@as(usize, 2), workbench.drag_tab_drop.?.index);

    // The strip paints upstream's drop-target-right line at the last tab edge.
    try workbench.render(&out.writer);
    const last = pane.hits.items[pane.hits.items.len - 1];
    const border = workbench.frame.prev.borderSetAt(last.end - 1, tab_y);
    try std.testing.expect(border.strokeAt(ui.cell_border.Segment.right) != null);

    var up = move;
    up.kind = .up;
    try std.testing.expect(workbench.handleTabDragMouse(&up));

    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    var ordered = std.array_list.Managed(*Tab).init(allocator);
    defer ordered.deinit();
    try pane.orderedTabs(allocator, &ordered);
    try std.testing.expectEqual(@as(usize, 2), ordered.items.len);
    try std.testing.expect(std.mem.endsWith(u8, ordered.items[0].editor.path, "strip_b.txt"));
    try std.testing.expect(std.mem.endsWith(u8, ordered.items[1].editor.path, "strip_a.txt"));
}

test "Workbench: dropping a tab on another strip inserts at the previewed index" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "strip_insert_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "strip_insert_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const source = workbench.part.group_views.items[0];
    const target = workbench.part.group_views.items[1];
    const source_y = ui.cell.snap(source.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = source.hits.items[0].start, .y = source_y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&down));

    // The right half of the target's only tab inserts after it.
    const target_y = ui.cell.snap(target.rect.y);
    const target_hit = target.hits.items[0];
    var move = ui.MouseEvent{
        .kind = .move,
        .x = target_hit.end - 1,
        .y = target_y,
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&move));
    try std.testing.expect(workbench.drag_tab_drop != null);
    try std.testing.expect(workbench.drag_tab_drop.?.pane == target);
    try std.testing.expectEqual(@as(usize, 1), workbench.drag_tab_drop.?.index);

    var up = move;
    up.kind = .up;
    try std.testing.expect(workbench.handleTabDragMouse(&up));

    // The source group empties and collapses; the target keeps the insert order.
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    const remaining = workbench.part.group_views.items[0];
    var ordered = std.array_list.Managed(*Tab).init(allocator);
    defer ordered.deinit();
    try remaining.orderedTabs(allocator, &ordered);
    try std.testing.expectEqual(@as(usize, 2), ordered.items.len);
    try std.testing.expect(std.mem.endsWith(u8, ordered.items[0].editor.path, "strip_insert_b.txt"));
    try std.testing.expect(std.mem.endsWith(u8, ordered.items[1].editor.path, "strip_insert_a.txt"));
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

test "Workbench: dragging the sidebar divider resizes the side bar" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "resize_a.txt", "alpha");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 12);
    defer workbench.deinit();
    try workbench.initSidebar(root);

    const before = workbench.sidebarWidth();
    const divider = workbench.activityBarWidth() + before;
    try std.testing.expect(workbench.sidebarShown());

    const down = ui.MouseEvent{ .kind = .down, .x = divider, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&down));
    try std.testing.expect(workbench.sidebar_resize_active);

    const move = ui.MouseEvent{ .kind = .move, .x = divider + 4, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&move));
    try std.testing.expectEqual(before + 4, workbench.sidebarWidth());

    const up = ui.MouseEvent{ .kind = .up, .x = divider + 4, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&up));
    try std.testing.expect(!workbench.sidebar_resize_active);

    // The same gesture clamps at the upstream-style half-window maximum.
    const far = ui.MouseEvent{ .kind = .down, .x = workbench.activityBarWidth() + workbench.sidebarWidth(), .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&far));
    const drag_far = ui.MouseEvent{ .kind = .move, .x = 10_000, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&drag_far));
    try std.testing.expectEqual(@as(usize, 35), workbench.sidebarWidth());
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

test "Workbench: opening a search result from another file does not restart the query" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = try seedFile(allocator, io, &tmp, "first.txt", "alpha beta\n");
    defer allocator.free(first);
    const second = try seedFile(allocator, io, &tmp, "second.txt", "gamma alpha\n");
    defer allocator.free(second);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{first}, 80, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    workbench.onSearchEditorChanged();
    try workbench.findInFiles();
    const view = workbench.search_view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    var guard: usize = 0;
    while (view.model.isSearching() and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../../base/common/timeCompat.zig").milliTimestamp());
    }
    try std.testing.expectEqual(@as(usize, 2), view.model.result.count());

    var second_row: ?usize = null;
    for (view.rows.items, 0..) |row, index| {
        switch (row) {
            .match => |match| {
                if (std.mem.eql(u8, match.parent_file.path, second)) {
                    second_row = index;
                    break;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(second_row != null);
    view.selected = second_row.?;
    view.results_focused = true;
    const enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expectEqual(@as(@TypeOf(view.handleKey(&enter)), .handled), view.handleKey(&enter));

    // The app reports the newly active editor after the click. Switching to
    // another file is not a content change, so it must not schedule a query.
    workbench.onSearchEditorChanged();
    _ = view.tick(@import("../../base/common/timeCompat.zig").milliTimestamp() + 600);
    try std.testing.expect(!view.model.isSearching());
    try std.testing.expectEqual(@as(usize, 2), view.model.result.count());
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

    // Upstream has no Settings view container: its activity bar gear is the
    // `workbench.actions.manage` global action that opens the Settings editor
    // as an editor tab, which is not ported. The rail therefore stops after
    // Source Control and a click below it changes nothing.
    const empty_rail_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 4 };
    try std.testing.expect(workbench.handleSidebarMouse(&empty_rail_click));
    try std.testing.expectEqual(@as(usize, 2), workbench.activeActivity());
    try std.testing.expectEqual(@as(usize, 3), workbench.activity_bar_part.count());

    // Problems is a panel container: no activity-bar entry and no sidebar
    // container (upstream registers it in `ViewContainerLocation.Panel`).
    try std.testing.expect(!try workbench.showActivityById("problems"));
    try std.testing.expect(!workbench.panelShown());

    const alt_1 = ui.KeyEvent{ .key = .{ .char = '1' }, .mods = .{ .alt = true } };
    try std.testing.expect(try workbench.handleSidebarKey(&alt_1));
    try std.testing.expectEqual(@as(usize, 0), workbench.activeActivity());
}

test "Workbench: side bar part paints the title and runs its actions" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "title_action.txt", "alpha beta\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 12);
    defer workbench.deinit();
    try workbench.initSidebar(root);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    // The title row belongs to the side bar part and the label is uppercased.
    const explorer_title = try workbench.frame.present().rowText(allocator, 0);
    defer allocator.free(explorer_title);
    try std.testing.expect(std.mem.indexOf(u8, explorer_title, "EXPLORER") != null);
    // The Explorer view has no header of its own: its first tree row follows
    // the title directly.
    const first_tree_row = try workbench.frame.present().rowText(allocator, 1);
    defer allocator.free(first_tree_row);
    try std.testing.expect(std.mem.indexOf(u8, first_tree_row, "title_action.txt") != null);

    // The title row, the content and the divider column share the side bar
    // background; only the divider glyph gets the border foreground.
    const side_bar_bg = ui.cell.packColor(ui.Color{ .r = 30, .g = 30, .b = 33 });
    const presented = workbench.frame.present();
    const title_right = workbench.activityBarWidth() + workbench.sidebarWidth() - 1;
    try std.testing.expectEqual(side_bar_bg, presented.bg[presented.index(title_right, 0)]);
    const divider = workbench.activityBarWidth() + workbench.sidebarWidth();
    try std.testing.expectEqual(side_bar_bg, presented.bg[presented.index(divider, 0)]);
    try std.testing.expectEqual(side_bar_bg, presented.bg[presented.index(divider, 5)]);
    try std.testing.expectEqual(
        ui.cell.packColor(ui.Color{ .r = 70, .g = 70, .b = 70 }),
        presented.fg[presented.index(divider, 5)],
    );

    try workbench.findInFiles();
    const view = workbench.search_view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    var guard: usize = 0;
    while ((view.model.isSearching() or view.wantsTick()) and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../../base/common/timeCompat.zig").milliTimestamp());
    }
    try std.testing.expect(view.rows.items.len > 0);
    const details_before = view.widget.details_visible;

    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    const search_title = try workbench.frame.present().rowText(allocator, 0);
    defer allocator.free(search_title);
    try std.testing.expect(std.mem.indexOf(u8, search_title, "SEARCH") != null);

    // The title toolbar hosts the active view's actions and runs them.
    const x0 = workbench.activityBarWidth();
    const width = workbench.sidebarWidth();
    const clear_click = ui.MouseEvent{ .kind = .down, .x = x0 + width - 5, .y = 0 };
    try std.testing.expect(workbench.handleSidebarMouse(&clear_click));
    try std.testing.expectEqual(@as(usize, 0), view.rows.items.len);

    const details_click = ui.MouseEvent{ .kind = .down, .x = x0 + width - 2, .y = 0 };
    try std.testing.expect(workbench.handleSidebarMouse(&details_click));
    try std.testing.expectEqual(!details_before, view.widget.details_visible);
}

test "Workbench: activity bar top moves the composite bar into the side bar" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    var settings = try tmp.dir.createFile(io, ".vscode/settings.json", .{});
    try settings.writeStreamingAll(io, "{\"workbench.activityBar.location\": \"top\"}");
    settings.close(io);

    const path = try seedFile(allocator, io, &tmp, "top_bar.txt", "alpha\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 12);
    defer workbench.deinit();
    try workbench.initSidebar(root);

    // The rail is gone and the side bar takes the left column.
    try std.testing.expectEqual(@as(usize, 0), workbench.activityBarWidth());
    try std.testing.expect(workbench.sidebar_part.shouldShowCompositeBar());
    try std.testing.expectEqual(@as(usize, 29), workbench.editorAreaX());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    // Row 0 is the composite bar, row 1 the title label, row 2 the content.
    const bar_row = try workbench.frame.present().rowText(allocator, 0);
    defer allocator.free(bar_row);
    try std.testing.expectEqual(@as(u8, 'E'), bar_row[1]);
    try std.testing.expectEqual(@as(u8, 'F'), bar_row[4]);
    const title_row = try workbench.frame.present().rowText(allocator, 1);
    defer allocator.free(title_row);
    try std.testing.expect(std.mem.indexOf(u8, title_row, "EXPLORER") != null);
    // The tree is the first thing below the title (`.vscode` sorts first).
    var found_file = false;
    for (2..5) |row| {
        const content_row = try workbench.frame.present().rowText(allocator, row);
        defer allocator.free(content_row);
        if (std.mem.indexOf(u8, content_row, "top_bar.txt") != null) found_file = true;
    }
    try std.testing.expect(found_file);

    // Clicking a composite bar item switches the view container.
    const search_click = ui.MouseEvent{ .kind = .down, .x = 4, .y = 0 };
    try std.testing.expect(workbench.handleSidebarMouse(&search_click));
    try std.testing.expectEqual(@as(usize, 1), workbench.activeActivity());

    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    const search_title = try workbench.frame.present().rowText(allocator, 1);
    defer allocator.free(search_title);
    try std.testing.expect(std.mem.indexOf(u8, search_title, "SEARCH") != null);
}

test "Workbench: closing the side bar keeps the activity bar" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "rail_closed.txt", "alpha\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 12);
    defer workbench.deinit();
    try workbench.initSidebar(root);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const rail_row = try workbench.frame.present().rowText(allocator, 1);
    defer allocator.free(rail_row);
    try std.testing.expectEqual(@as(u8, 'E'), rail_row[1]);

    _ = try workbench.commands.execute("workbench.action.closeSidebar");
    try std.testing.expect(!workbench.sidebar_part.isVisible());
    try std.testing.expectEqual(@as(usize, 3), workbench.editorAreaX());

    // The activity bar stays visible and clickable while the side bar is
    // closed; an entry click reveals the side bar again.
    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    const closed_rail_row = try workbench.frame.present().rowText(allocator, 1);
    defer allocator.free(closed_rail_row);
    try std.testing.expectEqual(@as(u8, 'E'), closed_rail_row[1]);
    const rail_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 1 };
    try std.testing.expect(workbench.handleSidebarMouse(&rail_click));
    try std.testing.expect(workbench.sidebar_part.isVisible());

    _ = try workbench.commands.execute("workbench.action.closeSidebar");
    _ = try workbench.commands.execute("workbench.action.focusSideBar");
    try std.testing.expect(workbench.sidebar_part.isVisible());
    try std.testing.expectEqual(Focus.sidebar, workbench.focus);
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
    try std.testing.expect(workbench.panelShown());
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.activePanelId());
    try std.testing.expectEqual(Focus.problems, workbench.focus);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "PROBLEMS") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "diag.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "boom") != null);
    try std.testing.expect(workbench.range_highlights.?.highlighted);

    const enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try workbench.handlePanelKey(&enter));
    try std.testing.expectEqual(@as(usize, 2), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
    try std.testing.expect(!workbench.range_highlights.?.highlighted);
}

test "Workbench: panel composite bar hosts Problems beside the Terminal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "panel.txt", "one\ntwo");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 90, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    try workbench.enableLanguageFeatures();
    try std.testing.expect(!workbench.panelShown());

    const service = workbench.marker_service orelse return error.TestUnexpectedResult;
    const tab = workbench.activeTab() orelse return error.TestExpectedTab;
    var resource = markers_mod.Resource.fromUri(allocator, tab.editor.model.uri()) catch return error.TestUnexpectedResult;
    defer resource.deinit(allocator);
    try service.changeOne("test", resource, &.{
        .{
            .severity = markers_mod.MarkerSeverity.Warning,
            .message = "careful",
            .start_line_number = 1,
            .start_column = 1,
            .end_line_number = 1,
            .end_column = 2,
        },
    }, null);

    // Markers alone do not reveal the panel, but they do publish the
    // `hideIfEmpty` Problems title; the Problems command opens the panel.
    try std.testing.expect(!workbench.panelShown());
    try std.testing.expect(workbench.panel_part.pane.bar.findItemConst(PROBLEMS_CONTAINER_ID).?.visible);
    try workbench.showProblems();
    try std.testing.expect(workbench.panelShown());
    try std.testing.expect(workbench.panel_part.pane.bar.findItemConst(PROBLEMS_CONTAINER_ID).?.visible);

    // Toggling Problems while it owns focus hides the panel; toggling again
    // reveals the same container.
    try workbench.toggleProblems();
    try std.testing.expect(!workbench.panelShown());
    try workbench.toggleProblems();
    try std.testing.expect(workbench.panelShown());
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.activePanelId());

    // Ctrl-J closes and re-opens the panel with its last active container.
    const ctrl_j = ui.KeyEvent{ .key = .{ .char = 'j' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_j));
    try std.testing.expect(!workbench.panelShown());
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_j));
    try std.testing.expect(workbench.panelShown());

    // Ctrl-Shift-M toggles Problems through the registered keybinding.
    const ctrl_shift_m = ui.KeyEvent{ .key = .{ .char = 'm' }, .mods = .{ .ctrl = true, .shift = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_shift_m));
    try std.testing.expect(!workbench.panelShown());
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_shift_m));
    try std.testing.expect(workbench.panelShown());
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.activePanelId());

    // The Terminal container shares the panel title; upstream order puts
    // Problems (order 0) before Terminal (order 3).
    const terminal_service = try TerminalService.init(allocator, io, .{ .launch = launchTestTerminal });
    workbench.terminal_service = terminal_service;
    workbench.newTerminal() catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqualStrings(TERMINAL_CONTAINER_ID, workbench.activePanelId());
    try std.testing.expect(workbench.terminalVisible());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const problems_index = std.mem.indexOf(u8, out.written(), "PROBLEMS") orelse return error.TestUnexpectedResult;
    const terminal_index = std.mem.indexOf(u8, out.written(), "TERMINAL") orelse return error.TestUnexpectedResult;
    try std.testing.expect(problems_index < terminal_index);

    // Clearing the markers drops the inactive Problems title again while the
    // panel and the Terminal tab stay.
    try service.changeOne("test", resource, &.{}, null);
    try std.testing.expect(!workbench.panel_part.pane.bar.findItemConst(PROBLEMS_CONTAINER_ID).?.visible);
    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "TERMINAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "PROBLEMS") == null);
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
    while (workbench.quickAccessWantsTick() and guard < 2000) : (guard += 1) {
        _ = try workbench.pollQuickAccess(0);
    }
    try std.testing.expectEqualStrings("alpha.txt", picker.activeItem().?.label);

    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expect(!workbench.isQuickAccessOpen());
    var open_guard: usize = 0;
    while (workbench.tabCount() == 0 and open_guard < 2000) : (open_guard += 1) {
        _ = workbench.pollAsyncReads();
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
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

test "Workbench: status bar context menu hides an entry" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "status_menu.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();

    const model = &workbench.statusbar.main_part.model;
    const entry = if (model.findEntry("status.editor.mode")) |found| found else &model.entries()[0];
    const id = entry.id;
    try workbench.showStatusbarContextMenu(entry.handle);
    try std.testing.expect(workbench.isQuickAccessOpen());
    const picker = workbench.quick_access.inputService().pickerRef();
    try std.testing.expect(std.mem.startsWith(u8, picker.activeItem().?.label, "Hide"));

    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expect(model.isHidden(id));
}

test "Workbench: tab close button honors the off setting" {
    try std.testing.expect(Workbench.tabCloseButtonVisible("right"));
    try std.testing.expect(Workbench.tabCloseButtonVisible("left"));
    try std.testing.expect(!Workbench.tabCloseButtonVisible("off"));
}

test "Workbench: duplicate tab labels show their directories" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "a/same.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "b/same.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 80, 10);
    defer workbench.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    const row = try workbench.frame.prev.rowText(allocator, ui.cell.snap(pane.rect.y));
    defer allocator.free(row);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, row, "same.txt"));
    try std.testing.expect(std.mem.indexOf(u8, row, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "b") != null);
}

test "Workbench: status bar escape clears the hover tooltip" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "status_escape.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();
    const part = workbench.statusbar.main_part;
    const entry = part.model.entries()[0];
    part.setHovered(entry.handle);
    try std.testing.expect(part.hovered != null);

    _ = workbench.runStatusbarCommand("workbench.action.statusbar.escapeFocus");
    try std.testing.expect(part.hovered == null);
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
    // The status bar mirrors VS Code: no quit hint is rendered.
    try std.testing.expect(std.mem.indexOf(u8, status, "Ctrl-Q") == null);
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
    .{ .id = "workbench.action.focusSideBar", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.Digit0) } },
    .{ .id = "workbench.action.focusStatusBar", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyS) } },
    .{ .id = markers_common.Markers.TOGGLE_MARKERS_VIEW_ACTION_ID, .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyM) } },
    .{ .id = "workbench.action.togglePanel", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyJ) } },
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

/// Reads, BOM-detects, decodes and canonicalizes a file. Runs on the async Io,
/// never on the TUI thread for interactive opens.
fn loadOpenText(allocator: Allocator, io: Io, path: []const u8) !editor_widget.LoadedText {
    const raw = Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        // The synchronous open path treats a missing file as a new, empty
        // buffer; keep that behavior for interactive opens too.
        error.FileNotFound => try allocator.alloc(u8, 0),
        else => return err,
    };
    defer allocator.free(raw);

    const encoding = if (encoding_mod.detectBOM(raw)) |bom| bom.encoding else .utf8;
    const text = try encoding_mod.decode(allocator, raw, encoding);
    errdefer allocator.free(text);
    const absolute = try editor_widget.absolutePath(allocator, io, path);
    return .{ .text = text, .encoding = encoding, .absolute_path = absolute };
}

fn runOpenJob(job: *OpenJob) OpenOutcome {
    defer job.done.store(true, .release);
    return .{ .text = loadOpenText(job.owner.allocator, job.owner.async_io, job.path) catch |err| return .{ .err = err } };
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
    var reload_guard: usize = 0;
    while (!workbench.pollReloadJobs() and reload_guard < 2000) : (reload_guard += 1) {
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(reload_guard < 2000);
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
    try std.testing.expect(workbench.workspace_watcher == null);
    try workbench.runContributionPhase(.after_restored);
    try std.testing.expect(workbench.workspace_watcher != null);
    try std.testing.expect(workbench.file_watcher_service != null);
}

test "Workbench: workspace watcher honors watcherExclude and watcherInclude" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    var settings = try tmp.dir.createFile(io, ".vscode/settings.json", .{});
    try settings.writeStreamingAll(
        io,
        "{\"files.watcherExclude\": {\"ignored/**\": true}, \"files.watcherInclude\": [\"included\"]}",
    );
    settings.close(io);
    try tmp.dir.createDirPath(io, "ignored");
    try tmp.dir.createDirPath(io, "included");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.runContributionPhase(.after_restored);

    const service = workbench.file_watcher_service.?;
    const included = try std.fs.path.join(allocator, &.{ root, "included" });
    defer allocator.free(included);

    var found_root = false;
    var found_included = false;
    var index: usize = 0;
    while (index < service.watchedCount()) : (index += 1) {
        const path = service.watchedPathAt(index) orelse continue;
        if (std.mem.eql(u8, path, root)) {
            found_root = true;
            const excludes = service.watchedExcludesAt(index) orelse &.{};
            var has_custom = false;
            var has_default = false;
            for (excludes) |exclude| {
                if (std.mem.eql(u8, exclude, "ignored/**")) has_custom = true;
                if (std.mem.eql(u8, exclude, ".git/objects/**")) has_default = true;
            }
            try std.testing.expect(has_custom);
            try std.testing.expect(has_default);
        }
        if (std.mem.eql(u8, path, included)) found_included = true;
    }
    try std.testing.expect(found_root);
    try std.testing.expect(found_included);
}

test "Workbench: AfterRestored watcher reloads a clean editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "watched.txt", "before");
    defer allocator.free(path);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    const tab = workbench.activeTab().?;

    try workbench.setWorkspaceFolders(&.{root});
    try workbench.runContributionPhase(.after_restored);
    const service = workbench.file_watcher_service.?;

    const ready_deadline = time_compat.milliTimestamp() + 3000;
    while (time_compat.milliTimestamp() < ready_deadline and !service.isReady()) {
        _ = workbench.pollFileWatcher(time_compat.milliTimestamp());
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(service.isReady());

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "after" });

    const deadline = time_compat.milliTimestamp() + 3000;
    var reloaded = false;
    while (time_compat.milliTimestamp() < deadline and !reloaded) {
        _ = workbench.pollFileWatcher(time_compat.milliTimestamp());
        var value = tab.editor.model.getValue(.TextDefined, true) catch break;
        reloaded = std.mem.eql(u8, value.items, "after");
        value.deinit();
        if (!reloaded) io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(reloaded);
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

test "Workbench: tab context menu closes the tab" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "menu_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "menu_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    try std.testing.expect(workbench.isQuickAccessOpen());
    const picker = workbench.quick_access.inputService().pickerRef();
    try std.testing.expectEqualStrings("Close", picker.activeItem().?.label);

    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
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

    // The tab header and the breadcrumb file segment use the Explorer's icon.
    const expected_icon = file_icon.file("http-proxy.js");
    const tab_row = ui.cell.snap(pane.rect.y);
    const tab_icon_cell = pane.hits.items[0].start + 1;
    try std.testing.expectEqual(
        @as(u32, expected_icon.glyph),
        workbench.frame.prev.cluster[workbench.frame.prev.index(tab_icon_cell, tab_row)],
    );
    try std.testing.expectEqual(
        ui.cell.packColor(expected_icon.color),
        workbench.frame.prev.fg[workbench.frame.prev.index(tab_icon_cell, tab_row)],
    );
    const file_item = control.widget.items.items[control.widget.itemCount() - 1];
    const breadcrumb_icon = switch (file_item.icon) {
        .glyph => |glyph| glyph,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(expected_icon.glyph, breadcrumb_icon.codepoint);
    try std.testing.expectEqual(expected_icon.color, breadcrumb_icon.color);

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

    try std.testing.expect(workbench.repository != null);
    try std.testing.expect(workbench.scm_view != null);
    try std.testing.expect(workbench.quick_diff_controller != null);
    const initial_tabs = workbench.tabCount();
    const provider = workbench.repository.?;
    try std.testing.expect(provider.count() >= 3);
    try std.testing.expect(workbench.scm_view.?.resourceCount() >= 3);

    // The Changes view honors the upstream view-mode and sort commands.
    {
        const view = workbench.scm_view.?;
        try std.testing.expectEqual(scm_common.ViewMode.list, view.viewMode());
        try std.testing.expectEqual(scm_view_mod.ViewSortKey.path, view.viewSortKey());
        _ = try workbench.commands.execute(scm_view_mod.SET_SORT_BY_NAME_ACTION_ID);
        try std.testing.expectEqual(scm_view_mod.ViewSortKey.name, view.viewSortKey());
        _ = try workbench.commands.execute(scm_view_mod.SET_SORT_BY_PATH_ACTION_ID);
        try std.testing.expectEqual(scm_view_mod.ViewSortKey.path, view.viewSortKey());
        _ = try workbench.commands.execute(scm_view_mod.SET_TREE_VIEW_MODE_ACTION_ID);
        try std.testing.expectEqual(scm_common.ViewMode.tree, view.viewMode());
        try std.testing.expect(view.resourceCount() >= 3);
        _ = try workbench.commands.execute(scm_view_mod.SET_LIST_VIEW_MODE_ACTION_ID);
        try std.testing.expectEqual(scm_common.ViewMode.list, view.viewMode());
    }

    // The SCM container stacks the Changes and Graph sections and the Graph
    // lists the repository commits.
    try std.testing.expect(workbench.scm_container != null);
    try std.testing.expect(workbench.scm_view_model != null);
    try std.testing.expect(workbench.scm_history_view != null);
    const visible_views = try workbench.scm_view_model.?.visibleViews(allocator);
    defer allocator.free(visible_views);
    try std.testing.expectEqual(@as(usize, 2), visible_views.len);
    try std.testing.expectEqualStrings("changes", visible_views[0].id);
    try std.testing.expectEqualStrings("graph", visible_views[1].id);

    workbench.refreshGitStatus();
    const history_view = workbench.scm_history_view.?;
    try history_view.refresh(.reload);
    try std.testing.expect(history_view.view_models.len > 0);
    try std.testing.expect(history_view.rows.items.len > 0);
    try std.testing.expect(history_view.hasCurrentHistoryItem() or history_view.view_models.len > 0);

    // Collapsing the Graph section keeps the header and gives the space to
    // Changes; rendering both states must not crash.
    _ = try workbench.showActivityById("scm");
    workbench.scm_view_model.?.setCollapsed("graph", true);
    try std.testing.expect(workbench.scm_view_model.?.isCollapsed("graph"));
    var scm_frame: std.Io.Writer.Allocating = .init(allocator);
    defer scm_frame.deinit();
    try workbench.render(&scm_frame.writer);
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "SOURCE CONTROL") != null);
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "Graph") != null);
    // Changes renders the staged and working groups and their file names.
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "Staged Changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "staged.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "untracked.txt") != null);
    // The commit-message input is pinned above the list with the branch in
    // its placeholder and the check button at the right.
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "Message (Enter to commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "\u{2713} Commit") != null);
    try std.testing.expectEqualStrings(
        "Message (Enter to commit on \"main\")",
        workbench.scm_interface.?.repositories()[0].input.placeholder(),
    );
    workbench.scm_view_model.?.setCollapsed("graph", false);

    // A mode-1003 idle motion over a section header must not toggle it or run
    // its title actions; only a press does.
    {
        const container = workbench.scm_container.?;
        var changes_header: ?ui.Rect = null;
        for (container.sections.items) |section| {
            if (std.mem.eql(u8, section.id, "changes")) changes_header = section.header_rect;
        }
        const header = changes_header orelse return error.TestExpectedChangesHeader;
        var hover = ui.MouseEvent{
            .kind = .move,
            .x = ui.cell.snap(header.x) + 2,
            .y = ui.cell.snap(header.y),
        };
        try std.testing.expect(workbench.handleSidebarMouse(&hover));
        try std.testing.expect(!workbench.scm_view_model.?.isCollapsed("changes"));
        hover.kind = .down;
        try std.testing.expect(workbench.handleSidebarMouse(&hover));
        try std.testing.expect(workbench.scm_view_model.?.isCollapsed("changes"));
        try std.testing.expect(workbench.handleSidebarMouse(&hover));
        try std.testing.expect(!workbench.scm_view_model.?.isCollapsed("changes"));
    }

    // The history hover is a bordered overlay: every edge of its surface must
    // carry a border glyph. The DOM root is four cells smaller than the
    // surface (one cell border plus one cell padding on each side); sizing the
    // content box to the whole surface used to clip the right/bottom edges.
    var hover_frame: std.Io.Writer.Allocating = .init(allocator);
    defer hover_frame.deinit();
    try workbench.render(&hover_frame.writer);
    history_view.clearHover();
    history_view.hovered_row = 0;
    history_view.hover_content = try allocator.dupe(u8, "7d272ae workbench: report Explorer open failures on click\nA single click opened a preview editor and discarded the change.\nthat Enter and the async open path use, and keep focus in the editor.");
    var hovered_frame: std.Io.Writer.Allocating = .init(allocator);
    defer hovered_frame.deinit();
    try workbench.render(&hovered_frame.writer);
    const hover_surface = &(workbench.scm_hover_surface orelse return error.TestExpectedHoverSurface);
    const hover_grid = hover_surface.grid();
    try std.testing.expect(hover_grid.cols >= 12 and hover_grid.rows >= 5);
    try std.testing.expectEqual(@as(u32, '┌'), hover_grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, '┐'), hover_grid.cluster[hover_grid.cols - 1]);
    try std.testing.expectEqual(@as(u32, '└'), hover_grid.cluster[(hover_grid.rows - 1) * hover_grid.cols]);
    try std.testing.expectEqual(@as(u32, '┘'), hover_grid.cluster[hover_grid.rows * hover_grid.cols - 1]);
    history_view.clearHover();

    // Expanding the first commit appends its changed-file rows.
    history_view.selection = 0;
    const rows_before_expand = history_view.rows.items.len;
    _ = try history_view.handleKey(&.{ .key = .right });
    try std.testing.expect(history_view.rows.items.len > rows_before_expand);

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

    // Opening a changed file from the Graph uses the parent/commit snapshot
    // diff; root commits compare against the empty tree.
    var change_row: ?usize = null;
    for (history_view.rows.items, 0..) |row, row_index| {
        if (std.meta.activeTag(row) == .change) {
            change_row = row_index;
            break;
        }
    }
    try std.testing.expect(change_row != null);
    history_view.selection = change_row.?;
    _ = try history_view.handleKey(&.{ .key = .enter });
    const commit_tab = workbench.activeTab() orelse return error.TestExpectedTab;
    try std.testing.expect(commit_tab.isDiff());
    try std.testing.expect(std.mem.indexOf(u8, commit_tab.input.getName(), "\u{2194}") != null);
    try std.testing.expect(std.mem.indexOf(u8, commit_tab.input.getName(), "Empty") != null);

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

    // The commit input commits the index. The `git.commit` command reads the
    // SCM input model, like upstream's command.
    {
        var input = workbench.scm_interface.?.repositories()[0].input;
        input.setValue("scm commit message", false);
        workbench.scm_view.?.refresh();
        try std.testing.expect(provider.repository.stateRef().index_changes.len > 0);
        _ = try workbench.commands.execute("git.commit");
        const after_commit = provider.repository.stateRef();
        try std.testing.expectEqual(@as(usize, 0), after_commit.index_changes.len);
        try std.testing.expect(after_commit.working_tree_changes.len > 0);
        try std.testing.expectEqualStrings("", input.value());
        const subject = try captureGitTest(allocator, root, &.{ "log", "-1", "--pretty=%s" });
        defer if (subject) |text| allocator.free(text);
        try std.testing.expect(subject != null);
        try std.testing.expect(std.mem.indexOf(u8, subject.?, "scm commit message") != null);

        // With an empty index the terminal's smart-commit path stages the
        // changed files before committing.
        input.setValue("smart commit", false);
        workbench.scm_view.?.refresh();
        _ = try workbench.commands.execute("git.commit");
        const after_smart = provider.repository.stateRef();
        try std.testing.expectEqual(@as(usize, 0), after_smart.index_changes.len);
        try std.testing.expectEqual(@as(usize, 0), after_smart.working_tree_changes.len);
        try std.testing.expectEqual(@as(usize, 0), after_smart.untracked_changes.len);
        const smart_subject = try captureGitTest(allocator, root, &.{ "log", "-1", "--pretty=%s" });
        defer if (smart_subject) |text| allocator.free(text);
        try std.testing.expect(smart_subject != null);
        try std.testing.expect(std.mem.indexOf(u8, smart_subject.?, "smart commit") != null);
    }
}

test "Workbench: clicking Load More pages the SCM history" {
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
    var number: usize = 0;
    while (number < 4) : (number += 1) {
        const contents = try std.fmt.allocPrint(allocator, "commit {d}\n", .{number});
        defer allocator.free(contents);
        try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = contents });
        if (!try runGitTest(allocator, root, &.{ "add", "a.txt" })) return error.SkipZigTest;
        const message = try std.fmt.allocPrint(allocator, "commit {d}", .{number});
        defer allocator.free(message);
        if (!try runGitTest(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", message })) return error.SkipZigTest;
    }

    const path = try std.fmt.allocPrint(allocator, "{s}/a.txt", .{root});
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 100, 30);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    try workbench.initGit();
    _ = try workbench.showActivityById("scm");

    const view = workbench.scm_history_view orelse return error.TestExpectedHistoryView;
    view.setConfig(.{ .page_size = 2, .page_on_scroll = false });
    try view.refresh(.reload);
    try std.testing.expectEqual(@as(usize, 3), view.rows.items.len);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const container = workbench.scm_container orelse return error.TestExpectedScmContainer;
    const body = container.bodyRect("graph") orelse return error.TestExpectedGraphBody;
    try std.testing.expect(ui.cell.snap(body.h) >= 3);
    const x = ui.cell.snap(body.x) + 2;
    const y = ui.cell.snap(body.y) + 2;
    var click = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleSidebarMouse(&click));
    try std.testing.expectEqual(@as(usize, 4), view.rows.items.len);
}

fn captureGitTest(allocator: Allocator, root: []const u8, args: []const []const u8) !?[]u8 {
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
    }) catch return null;
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) {
        allocator.free(result.stdout);
        return null;
    }
    return result.stdout;
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

    const layout = terminal_panel.layout(workbench.panelContentRect());
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

const test_png_1x1 = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
    0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
    0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,
};

fn seedBinary(
    allocator: Allocator,
    io: Io,
    tmp: *std.testing.TmpDir,
    name: []const u8,
    contents: []const u8,
) ![]u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = contents });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPathFile(io, name, &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

fn paneTextAlloc(allocator: Allocator, pane: *@import("../../../tui/imagePreview.zig").ImagePreviewPane) ![]u8 {
    const surface = &(pane.surface orelse return allocator.alloc(u8, 0));
    var text = std.array_list.Managed(u8).init(allocator);
    errdefer text.deinit();
    var row: usize = 0;
    while (row < surface.grid().rows) : (row += 1) {
        const line = try surface.grid().rowText(allocator, row);
        defer allocator.free(line);
        try text.appendSlice(line);
        try text.append('\n');
    }
    return text.toOwnedSlice();
}

test "Workbench: image files open in an image preview tab without touching the file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 12);
    defer workbench.deinit();
    const tab = workbench.activeTab().?;
    try std.testing.expect(tab.isImage());
    try std.testing.expect(tab.image_input != null);
    try std.testing.expect(tab.file_input == null);
    try std.testing.expect(tab.editor.read_only);
    try std.testing.expectEqualStrings("logo.png", tab.input.getName());

    // No kitty support: the pane renders the message instead of alt/binary text.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const message_text = try paneTextAlloc(allocator, tab.image_preview.?);
    defer allocator.free(message_text);
    try std.testing.expect(std.mem.indexOf(u8, message_text, "kitty graphics") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "kitty graphics") != null);

    // Ctrl-S is a no-op for image tabs.
    try workbench.commands.execute("workbench.action.files.save");
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &test_png_1x1, bytes);
}

test "Workbench: a capable terminal uploads and paints the image" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 12);
    defer workbench.deinit();
    workbench.setImageProtocol(.unicode_placeholders);
    workbench.setCellPixelSize(8, 16);
    const tab = workbench.activeTab().?;
    try std.testing.expect(tab.isImage());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b_Ga=t,f=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\u{10EEEE}") != null);
    var saw_placeholder = false;
    const surface = &tab.image_preview.?.surface.?;
    var row: usize = 0;
    while (row < surface.grid().rows) : (row += 1) {
        var col: usize = 0;
        while (col < surface.grid().cols) : (col += 1) {
            if (surface.grid().cluster[surface.grid().index(col, row)] == ui.image.placeholder_codepoint) saw_placeholder = true;
        }
    }
    try std.testing.expect(saw_placeholder);

    // The zoom command updates the viewer and the status entries.
    try workbench.commands.execute("imagePreview.zoomIn");
    workbench.refreshStatus();
    try std.testing.expect(workbench.media_status.?.last.scale != null);
    const scale = tagScale(workbench.media_status.?.last.scale.?);
    try std.testing.expect(scale > 1);

    // Zoomed clicks change the pane's scale too.
    var click = ui.MouseEvent{ .kind = .down, .button = .left, .x = 2, .y = 2 };
    try std.testing.expectEqual(
        @import("../../../tui/imagePreview.zig").Action.changed,
        tab.handleImageMouse(&click, false),
    );
}

fn tagScale(scale: @import("../contrib/mediaPreview/browser/imageViewer.zig").Scale) f64 {
    return switch (scale) {
        .fit => 1,
        .number => |value| value,
    };
}

test "Workbench: image files reload on change and open in a text editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 12);
    defer workbench.deinit();
    workbench.setImageProtocol(.unicode_placeholders);
    const tab = workbench.activeTab().?;
    const pane = tab.image_preview.?;
    const before = pane.editor.load_id;

    workbench.handleFileChanges(&.{.{ .type = .UPDATED, .resource = path }});
    try std.testing.expect(pane.editor.load_id > before);
    try std.testing.expect(workbench.pollFileWatcher(time_compat.milliTimestamp()));

    try workbench.openActiveImageAsText();
    const text_tab = workbench.activeTab().?;
    try std.testing.expect(!text_tab.isImage());
    try std.testing.expectEqualStrings("logo.png", text_tab.input.getName());
}

test "Workbench: session serialization restores image tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 12);
    defer workbench.deinit();

    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    var file_serializer = FileEditorSerializer.init(allocator, io, 40, 10);
    _ = try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, file_serializer.interface());
    var image_serializer = ImagePreviewEditorInputSerializer.init(allocator);
    _ = try registry.registerEditorSerializer(ImagePreviewEditorInput.ID, image_serializer.interface());

    var serialized = try workbench.serializePart(allocator, &registry);
    defer serialized.deinit(allocator);

    const restored = try Workbench.initFromSerializedPart(allocator, io, serialized, &registry, 40, 12);
    defer restored.deinit();
    const restored_tab = restored.activeTab().?;
    try std.testing.expect(restored_tab.isImage());
    try std.testing.expectEqualStrings("logo.png", restored_tab.input.getName());
}

test "Workbench: markdown preview shows displayable images" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try seedBinary(allocator, io, &tmp, "shot.png", &test_png_1x1);
    defer allocator.free(image_path);
    const markdown_path = try seedFile(allocator, io, &tmp, "with-image.md", "# Title\n\n![shot](shot.png)\n");
    defer allocator.free(markdown_path);

    const workbench = try Workbench.init(allocator, io, &.{markdown_path}, 70, 18);
    defer workbench.deinit();
    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    try workbench.toggleMarkdownPreview(pane);
    try std.testing.expect(tab.markdown_preview_visible);

    // Without placeholder support the alt text is preserved and no image is
    // loaded into the document.
    var plain: std.Io.Writer.Allocating = .init(allocator);
    defer plain.deinit();
    try workbench.render(&plain.writer);
    try std.testing.expectEqual(@as(usize, 0), tab.markdown_preview.?.document.?.images.len);
    var saw_alt = false;
    const preview_surface = &tab.markdown_preview.?.surface.?;
    var alt_row: usize = 0;
    while (alt_row < preview_surface.grid().rows) : (alt_row += 1) {
        const text = try preview_surface.grid().rowText(allocator, alt_row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "shot") != null) saw_alt = true;
    }
    try std.testing.expect(saw_alt);

    workbench.setImageProtocol(.unicode_placeholders);
    workbench.setCellPixelSize(8, 16);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\u{10EEEE}") != null);

    const preview = tab.markdown_preview.?;
    try std.testing.expect(preview.document != null);
    try std.testing.expectEqual(@as(usize, 1), preview.document.?.images.len);
}

test "Workbench: closing an image tab releases the terminal image" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 12);
    defer workbench.deinit();
    workbench.setImageProtocol(.unicode_placeholders);
    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try workbench.render(&first.writer);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "a=t,f=100") != null);

    try workbench.commands.execute("workbench.action.closeActiveEditor");
    try std.testing.expect(workbench.images.hasPending());
    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();
    try workbench.render(&second.writer);
    try std.testing.expect(std.mem.indexOf(u8, second.written(), "a=d,d=I") != null);
}

test "Workbench: interactive open reads on the async Io" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "async-open.txt", "async body");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 10);
    defer workbench.deinit();

    workbench.requestOpenPath(path);
    try std.testing.expect(workbench.pending_open != null);
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    var waited: usize = 0;
    while (!workbench.pollAsyncReads() and waited < 2000) : (waited += 1) {
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    const tab = workbench.activeTab().?;
    var content = try tab.editor.model.getLineContent(1);
    defer content.deinit();
    try std.testing.expectEqualStrings("async body", content.items);
}

test "Workbench: cancelling an in-flight open leaves no tab and no pending job" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "cancel-open.txt", "body");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 10);
    workbench.requestOpenPath(path);
    workbench.deinit();
}

test "Workbench: Explorer expands a directory symlink and opens a file inside" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const ExplorerItem = @import("../contrib/files/common/explorerModel.zig").ExplorerItem;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "real");
    var inner = try tmp.dir.createFile(io, "real/inner.txt", .{});
    try inner.writeStreamingAll(io, "inside link");
    inner.close(io);
    try tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const inner_path = try std.fmt.allocPrint(allocator, "{s}/link/inner.txt", .{root});
    defer allocator.free(inner_path);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    workbench.focusSidebar();

    const sidebar = workbench.sidebar.?;
    const link = sidebar.model.roots.items[0].getChild("link").?;
    try std.testing.expect(link.is_directory);
    try std.testing.expect(link.is_symbolic_link);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const rect = sidebar.last_rect;
    const left = ui.cell.snap(rect.x);
    const top = ui.cell.snap(rect.y) + sidebar.header_rows;

    const RowPosition = struct {
        fn find(sidebar_: *Sidebar, item: *ExplorerItem) ?usize {
            var index: usize = 0;
            while (index < sidebar_.count()) : (index += 1) {
                if (sidebar_.renderedItem(index) == item) return index;
            }
            return null;
        }
    };

    // A single click on the twistie expands the linked directory; before the
    // type was resolved the row was a file and the click tried to open it.
    const link_click = ui.MouseEvent{
        .kind = .down,
        .x = left + 2,
        .y = top + (RowPosition.find(sidebar, link) orelse return error.TestUnexpectedResult),
        .button = .left,
    };
    try std.testing.expect(workbench.handleSidebarMouse(&link_click));
    try std.testing.expect(sidebar.hasPendingLoad());
    var load_waited: usize = 0;
    while (!sidebar.pollLoad() and load_waited < 2000) : (load_waited += 1) {
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(load_waited < 2000);
    try std.testing.expect(sidebar.isExpanded(link));
    const inner_item = link.getChild("inner.txt") orelse return error.TestUnexpectedResult;

    // A single click on the child opens it through the link path and reads the
    // target, so files inside a linked directory have their real content.
    try workbench.render(&out.writer);
    const inner_click = ui.MouseEvent{
        .kind = .down,
        .x = left + 2,
        .y = top + (RowPosition.find(sidebar, inner_item) orelse return error.TestUnexpectedResult),
        .button = .left,
    };
    try std.testing.expect(workbench.handleSidebarMouse(&inner_click));
    const tab = workbench.activeTab() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(inner_path, tab.editor.path);
    var content = try tab.editor.model.getLineContent(1);
    defer content.deinit();
    try std.testing.expectEqualStrings("inside link", content.items);
}

test "Workbench: explorer sticky headers pin the folder ancestors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "aaa/bbb/ccc");
    var file_a = try tmp.dir.createFile(io, "aaa/a.txt", .{});
    try file_a.writeStreamingAll(io, "a");
    file_a.close(io);
    var file_b = try tmp.dir.createFile(io, "aaa/bbb/b.txt", .{});
    try file_b.writeStreamingAll(io, "b");
    file_b.close(io);
    for (0..12) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "aaa/bbb/ccc/f{d:0>2}.txt", .{i});
        var file = try tmp.dir.createFile(io, name, .{});
        try file.writeStreamingAll(io, "x");
        file.close(io);
    }

    const seed = try seedFile(allocator, io, &tmp, "sticky_seed.txt", "seed");
    defer allocator.free(seed);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{seed}, 60, 14);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    workbench.focusSidebar();

    var first_frame: std.Io.Writer.Allocating = .init(allocator);
    defer first_frame.deinit();
    try workbench.render(&first_frame.writer);

    const sidebar = workbench.sidebar.?;
    const deep = try std.fmt.allocPrint(allocator, "{s}/aaa/bbb/ccc/f11.txt", .{root});
    defer allocator.free(deep);
    try sidebar.revealPath(deep);

    var frame: std.Io.Writer.Allocating = .init(allocator);
    defer frame.deinit();
    try workbench.render(&frame.writer);

    try std.testing.expectEqual(@as(usize, 3), sidebar.tree.stickyScrollNodes().len);
    const sticky_a = try workbench.frame.present().rowText(allocator, 1);
    defer allocator.free(sticky_a);
    const sticky_b = try workbench.frame.present().rowText(allocator, 2);
    defer allocator.free(sticky_b);
    const sticky_c = try workbench.frame.present().rowText(allocator, 3);
    defer allocator.free(sticky_c);
    try std.testing.expect(std.mem.indexOf(u8, sticky_a, "aaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, sticky_b, "bbb") != null);
    try std.testing.expect(std.mem.indexOf(u8, sticky_c, "ccc") != null);

    // Tab moves the focus into the sticky widget; Escape leaves the widget
    // before the side bar returns focus to the editor.
    var tab = ui.KeyEvent{ .key = .tab };
    try std.testing.expect(try workbench.handleSidebarKey(&tab));
    try std.testing.expect(sidebar.tree.stickyScrollFocused());
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(try workbench.handleSidebarKey(&escape));
    try std.testing.expect(!sidebar.tree.stickyScrollFocused());
    try std.testing.expectEqual(Focus.sidebar, workbench.focus);

    // A second Escape leaves the side bar for the editor, as before.
    try std.testing.expect(try workbench.handleSidebarKey(&escape));
    try std.testing.expectEqual(Focus.editor, workbench.focus);
}

test "Workbench: right click on a tab neither closes nor activates it" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "right_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "right_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 40, 9);
    defer workbench.deinit();
    try workbench.activateIndex(1);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    const tab_x = pane.hits.items[0].start + 1;
    const tab_y = ui.cell.snap(pane.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = tab_x, .y = tab_y, .button = .right };
    try std.testing.expect(workbench.handleTabMouse(&down));
    try std.testing.expect(workbench.isQuickAccessOpen());
    var escape = ui.KeyEvent{ .key = .escape };
    _ = try workbench.handleQuickAccessKey(&escape);

    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqualStrings("right_b.txt", workbench.activeTab().?.input.getName());
}

test "Workbench: inactive breadcrumbs reuse a persistent control" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "crumb_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "crumb_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expectEqual(@as(usize, 1), workbench.breadcrumbs_inactive.count());
    const first = workbench.breadcrumbs_inactive.get(workbench.part.group_views.items[0].group.id).?;

    try workbench.render(&out.writer);
    try std.testing.expectEqual(@as(usize, 1), workbench.breadcrumbs_inactive.count());
    try std.testing.expectEqual(first, workbench.breadcrumbs_inactive.get(workbench.part.group_views.items[0].group.id).?);
}

test "Workbench: hover shows the marker message" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "hover-diagnostic.txt", "one\ntwo\nthree");
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
            .source = "test",
            .start_line_number = 2,
            .start_column = 1,
            .end_line_number = 2,
            .end_column = 4,
        },
    }, null);

    try tab.editor.setCursorPosition(Position.init(2, 2));
    try std.testing.expect(try workbench.showHover());
    const controllers = tab.controllers orelse return error.TestUnexpectedResult;
    try std.testing.expect(controllers.hover.isVisible());
    const content = controllers.hover.widget().getWidgetContent() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, content, "Error: boom") != null);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const rendered = try frameText(allocator, &workbench.frame);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "boom") != null);
}

test "Workbench: tab overflow lists clipped tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "overflow_a.txt", "a");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "overflow_b.txt", "b");
    defer allocator.free(path_b);
    const path_c = try seedFile(allocator, io, &tmp, "overflow_c.txt", "c");
    defer allocator.free(path_c);
    const path_d = try seedFile(allocator, io, &tmp, "overflow_d.txt", "d");
    defer allocator.free(path_d);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b, path_c, path_d }, 28, 10);
    defer workbench.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    try std.testing.expect(pane.hits.items.len > 0);
    try std.testing.expect(pane.hits.items.len < pane.tabs.items.len);
    const first_hit = pane.hits.items[0].start;
    try std.testing.expect(first_hit > 0);

    var down = ui.MouseEvent{
        .kind = .down,
        .x = ui.cell.snap(pane.rect.x),
        .y = ui.cell.snap(pane.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    try std.testing.expect(workbench.isQuickAccessOpen());
    const picker = workbench.quick_access.inputService().pickerRef();
    const hidden_name = picker.activeItem().?.label;

    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expectEqualStrings(hidden_name, workbench.activeTab().?.input.getName());
}

test "Workbench: tab context menu closes to the right" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "right_a.txt", "a");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "right_b.txt", "b");
    defer allocator.free(path_b);
    const path_c = try seedFile(allocator, io, &tmp, "right_c.txt", "c");
    defer allocator.free(path_c);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b, path_c }, 60, 12);
    defer workbench.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    const picker = workbench.quick_access.inputService().pickerRef();
    picker.setActiveIndex(2);
    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
}

test "Workbench: tab context menu splits the captured tab" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "split_a.txt", "a");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "split_b.txt", "b");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    const picker = workbench.quick_access.inputService().pickerRef();
    picker.setActiveIndex(6);
    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);

    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqualStrings("split_a.txt", workbench.activeTab().?.input.getName());
}

test "Workbench: tab context menu closes saved tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "saved_a.txt", "a");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "saved_b.txt", "b");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    defer workbench.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    const picker = workbench.quick_access.inputService().pickerRef();
    picker.setActiveIndex(3);
    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());
}

test "Workbench: close saved keeps dirty tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "dirty_saved_a.txt", "a");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "dirty_saved_b.txt", "b");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    defer workbench.deinit();
    try workbench.activateIndex(0);
    try workbench.activeTab().?.editor.insertText("x");
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    const picker = workbench.quick_access.inputService().pickerRef();
    picker.setActiveIndex(3);
    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);

    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("dirty_saved_a.txt", workbench.activeTab().?.input.getName());
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());
}

test "Workbench: hiding the tab row reclaims it for content" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "hidden_tabs.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 50, 10);
    defer workbench.deinit();
    const pane = workbench.part.group_views.items[0];
    pane.setBreadcrumbsVisible(false);
    pane.setTabsVisible(false);
    pane.layout();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const row = try workbench.frame.prev.rowText(allocator, ui.cell.snap(pane.rect.y));
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "hidden_tabs.txt") == null);
}

test "Workbench: the find bar reserves a view-zone row" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "find_zone.txt", "alpha\nbeta");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();
    const tab = workbench.activeTab().?;
    try tab.ensureControllers();
    tab.controllers.?.find.widget().open();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    const top = ui.cell.snap(pane.rect.y) + pane.chromeHeight();
    const row = try workbench.frame.prev.rowText(allocator, top + 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "alpha") != null);
    try std.testing.expectEqual(@as(usize, 1), tab.top_view_zone_rows);
}
