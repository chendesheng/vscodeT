// Port of the shared contribution registrations in `src/vs/workbench/workbench.common.main.ts`.
// Each Zig window owns its registries and delayed singleton instances.
const std = @import("std");
const ServiceCollection = @import("../platform/instantiation/common/serviceCollection.zig").ServiceCollection;
const MenuRegistry = @import("../platform/actions/common/actions.zig").MenuRegistry;

pub fn createServices(allocator: std.mem.Allocator) !ServiceCollection {
    var services = ServiceCollection.init(allocator);
    errdefer services.deinit();
    try @import("../editor/contrib/documentSymbols/browser/outlineModel.zig").registerSingleton(&services);
    try @import("../editor/contrib/codelens/browser/codeLensCache.zig").registerSingleton(&services);
    try @import("../editor/common/services/textResourceConfigurationService.zig").registerSingleton(&services);
    return services;
}

pub fn registerAccessibleViews(registry: *@import("../platform/accessibility/browser/accessibleViewRegistry.zig").AccessibleViewRegistry) !void {
    try registry.register(@import("contrib/codeEditor/browser/diffEditorAccessibilityHelp.zig").DiffEditorAccessibilityHelp.registration);
    try registry.register(@import("contrib/multiDiffEditor/browser/multiDiffEditorAccessibilityHelp.zig").MultiDiffEditorFileListAccessibilityHelp.registration);
}

pub fn registerConfigurations(registry: *@import("../platform/configuration/common/configurationRegistry.zig").ConfigurationRegistry) !void {
    try registry.registerConfiguration("multiDiffEditor", &@import("contrib/multiDiffEditor/common/multiDiffEditor.zig").properties);
    try registry.registerConfiguration("diffEditor", &@import("../editor/common/config/editorConfigurationSchema.zig").diff_editor_properties);
}

pub fn registerConfigurationMigrations(registry: *@import("common/configuration.zig").ConfigurationMigrationRegistry) !void {
    try registry.registerConfigurationMigrations(&@import("contrib/codeEditor/browser/diffEditorHelper.zig").configuration_migrations);
}

/// Workbench diff editor contribution registration, assembled once and
/// instantiated by every normal/restored diff widget at its pane boundary.
const diff_editor_contributions = [_]@import("../editor/browser/editorExtensions.zig").DiffEditorContributionRegistration{
    @import("contrib/codeEditor/browser/diffEditorHelper.zig").DiffEditorHelperContribution.registration,
};

pub fn attachDiffEditorContributions(accessor: @import("../platform/instantiation/common/instantiation.zig").ServicesAccessor, tab: *@import("browser/parts/editor/editorPane.zig").Tab) !void {
    if (tab.diff) |diff| try attachDiffWidgetContributions(accessor, diff.widget);
}

pub fn attachDiffWidgetContributions(accessor: @import("../platform/instantiation/common/instantiation.zig").ServicesAccessor, widget: *@import("browser/parts/editor/editorPane.zig").DiffWidget) !void {
    try widget.attachContributions(&diff_editor_contributions, accessor);
}

pub fn registerViewContainers(registry: *@import("common/views.zig").ViewContainersRegistry) !void {
    try @import("contrib/files/browser/explorerViewlet.zig").registerViewContainer(registry);
    try @import("contrib/search/browser/search.contribution.zig").registerViewContainer(registry);
    try @import("contrib/scm/browser/scm.contribution.zig").registerViewContainer(registry);
    try @import("contrib/markers/browser/markers.contribution.zig").registerViewContainer(registry);
    try @import("contrib/terminal/browser/terminal.contribution.zig").registerViewContainer(registry);
}

pub fn registerViews(registry: *@import("common/views.zig").ViewsRegistry) !void {
    try @import("contrib/files/browser/explorerViewlet.zig").registerViews(registry);
    try @import("contrib/outline/browser/outline.contribution.zig").registerViews(registry);
    try @import("contrib/scm/browser/scm.contribution.zig").registerViews(registry);
}

pub fn registerMenus(menus: *MenuRegistry) !void {
    try @import("contrib/scm/browser/scmViewPane.zig").registerMenus(menus);
    try @import("contrib/scm/browser/scmHistoryViewPane.zig").registerMenus(menus);
    try @import("contrib/outline/browser/outlineActions.zig").registerMenus(menus);
    try @import("contrib/multiDiffEditor/browser/actions.zig").registerMenus(menus);
}

const Action2 = @import("../platform/actions/common/actions.zig").Action2;
const CommandRegistry = @import("browser/commands.zig").CommandRegistry;
const InstantiationService = @import("../platform/instantiation/common/instantiationService.zig").InstantiationService;
const quick_access_mod = @import("browser/quickaccess.zig");
const terminal_actions = @import("contrib/terminal/browser/terminalActions.zig");
const scm_contribution = @import("contrib/scm/browser/scm.contribution.zig");
const scm_view_mod = @import("contrib/scm/browser/scmViewPane.zig");
const scm_history_view_mod = @import("contrib/scm/browser/scmHistoryViewPane.zig");
const markers_contribution = @import("contrib/markers/browser/markers.contribution.zig");
const zen_mode_contribution = @import("browser/workbench.zenMode.contribution.zig");
const activity_bar_mod = @import("browser/parts/activitybar/activitybarPart.zig");
const media_actions = @import("contrib/mediaPreview/browser/mediaPreviewActions.zig");
const sticky_actions = @import("../editor/contrib/stickyScroll/browser/stickyScrollActions.zig");
const hover_actions = @import("../editor/contrib/hover/browser/hoverActions.zig");

/// Explicit Zig registration replaces the side-effect imports of the
/// upstream common main and editor.all.ts. The native window supplies the
/// bound contribution instances, not a service locator or command table.
/// Built-in extension action descriptors retain their existing palette order.
pub const ActionContributions = struct {
    editor_status: *@import("browser/parts/editor/editorStatus.zig").EditorStatus,
    groups: *@import("browser/parts/editor/editorActions.zig").GroupActions,
    breadcrumbs: *@import("browser/parts/editor/breadcrumbsControl.zig").BreadcrumbsControlCollection,
    search_editor: *@import("contrib/searchEditor/browser/searchEditor.contribution.zig").SearchEditorFactory,
    github_publish: Action2,
    simple_browser: []const Action2,
    git_refresh: []const Action2,
    git_remote: []const Action2,
    git_open: []const Action2,
    git_diff: []const Action2,
    markdown: []const Action2,
};

pub fn registerActions(commands: *CommandRegistry, instantiation: *InstantiationService, contributions: ActionContributions) !void {
    const panel_actions = @import("browser/parts/panel/panelActions.zig");
    try commands.registerAction(instantiation, quick_access_mod.quick_open_action);
    try commands.registerAction(instantiation, @import("contrib/quickaccess/browser/commandsQuickAccess.zig").ShowAllCommandsAction.descriptor);
    for (contributions.editor_status.actionDescriptors()) |action| try commands.registerAction(instantiation, action);
    for (@import("contrib/files/browser/fileCommands.zig").editor_actions) |action| try commands.registerAction(instantiation, action);
    for (@import("browser/actions/listCommands.zig").list_actions) |action| try commands.registerAction(instantiation, action);
    try commands.registerAction(instantiation, contributions.github_publish);
    for (contributions.simple_browser) |action| try commands.registerAction(instantiation, action);
    for (@import("contrib/preferences/browser/preferences.contribution.zig").preferences_actions) |action| try commands.registerAction(instantiation, action);
    try @import("browser/parts/editor/editorTabsControl.zig").registerEditorTitleContext(&commands.menus);
    try @import("contrib/terminal/browser/terminalActions.zig").registerEditorTitleContext(&commands.menus);
    for (contributions.groups.closeAndReopenActions()) |action| try commands.registerAction(instantiation, action);
    for (contributions.breadcrumbs.focusActions()) |action| try commands.registerAction(instantiation, action);
    const outline_actions = @import("contrib/outline/browser/outlineActions.zig");
    try commands.registerAction(instantiation, outline_actions.focus_action);
    try commands.registerAction(instantiation, outline_actions.more_actions);
    for (outline_actions.outline_actions) |action| try commands.registerAction(instantiation, action);
    for (contributions.groups.splitActions()) |action| try commands.registerAction(instantiation, action);
    for (@import("browser/parts/editor/editorActions.zig").focus_group_actions) |action| try commands.registerAction(instantiation, action);
    const editor_actions = @import("browser/parts/editor/editorActions.zig");
    for (editor_actions.new_group_actions) |action| try commands.registerAction(instantiation, action);
    for (contributions.groups.joinActions()) |action| try commands.registerAction(instantiation, action);
    for (editor_actions.move_group_actions) |action| try commands.registerAction(instantiation, action);
    for (contributions.groups.transferActions()) |action| try commands.registerAction(instantiation, action);
    for (@import("browser/actions/navigationActions.zig").navigation_actions) |action| try commands.registerAction(instantiation, action);
    try commands.registerAction(instantiation, editor_actions.navigate_between_groups_action);
    try commands.registerAction(instantiation, editor_actions.reset_group_sizes_action);
    for (@import("browser/actions/layoutActions.zig").resize_actions) |action| try commands.registerAction(instantiation, action);
    try commands.registerAction(instantiation, editor_actions.maximize_editor_action);
    try commands.registerAction(instantiation, panel_actions.close_panel_action);
    try commands.registerAction(instantiation, panel_actions.toggle_maximized_panel_action);
    for (panel_actions.positioning_actions) |action| try commands.registerAction(instantiation, action);
    for (contributions.groups.closeEditorsActions()) |action| try commands.registerAction(instantiation, action);
    try commands.registerAction(instantiation, contributions.groups.joinAllAction());
    for (contributions.groups.navigationActions()) |action| try commands.registerAction(instantiation, action);
    try commands.registerAction(instantiation, terminal_actions.editor_action);
    try commands.registerAction(instantiation, @import("contrib/files/browser/explorerViewlet.zig").show_explorer_action);
    try commands.registerAction(instantiation, scm_contribution.show_scm_action);
    for (markers_contribution.view_actions) |action| try commands.registerAction(instantiation, action);
    try commands.registerAction(instantiation, panel_actions.toggle_panel_action);
    try panel_actions.registerPanelTitle(&commands.menus);
    try commands.registerAction(instantiation, zen_mode_contribution.toggle_action);
    try commands.registerAction(instantiation, zen_mode_contribution.exit_action);
    try commands.registerAction(instantiation, @import("browser/actions/layoutActions.zig").toggle_centered_layout_action);
    for (@import("browser/actions/layoutActions.zig").zen_tabs_actions) |action| try commands.registerAction(instantiation, action);
    for (panel_actions.focus_and_switch_actions) |action| try commands.registerAction(instantiation, action);
    for (contributions.git_refresh) |action| try commands.registerAction(instantiation, action);
    try commands.registerAction(instantiation, scm_view_mod.changes_menu_action);
    try commands.registerAction(instantiation, scm_history_view_mod.graph_menu_action);
    try commands.registerAction(instantiation, scm_contribution.show_menu_action);
    for (contributions.git_remote) |action| try commands.registerAction(instantiation, action);
    for (scm_contribution.view_actions) |action| try commands.registerAction(instantiation, action);
    for (contributions.git_open) |action| try commands.registerAction(instantiation, action);
    for (contributions.git_diff) |action| try commands.registerAction(instantiation, action);
    const quick_diff_widget = @import("contrib/scm/browser/quickDiffWidget.zig");
    for (quick_diff_widget.editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (quick_diff_widget.widget_actions) |action| try commands.registerAction(instantiation, action);
    try quick_diff_widget.registerGoMenu(&commands.menus);
    try @import("contrib/multiDiffEditor/browser/multiDiffEditor.contribution.zig").registerActions(commands, instantiation);
    for (@import("browser/parts/editor/diffEditorCommands.zig").diff_actions) |action| try commands.registerAction(instantiation, action);
    for (@import("../editor/browser/widget/diffEditor/commands.zig").diff_actions) |action| try commands.registerAction(instantiation, action);
    for (@import("contrib/accessibility/browser/accessibleViewActions.zig").accessible_view_actions) |action| try commands.registerAction(instantiation, action);
    try @import("browser/parts/editor/editor.contribution.zig").registerDiffEditorTitle(&commands.menus);
    try commands.registerAction(instantiation, @import("browser/actions/layoutActions.zig").toggle_sidebar_visibility_action);
    for (@import("browser/parts/sidebar/sidebarActions.zig").sidebar_actions) |action| try commands.registerAction(instantiation, action);
    for (activity_bar_mod.switch_sidebar_actions) |action| try commands.registerAction(instantiation, action);
    const statusbar_actions = @import("browser/parts/statusbar/statusbarActions.zig");
    try commands.registerAction(instantiation, statusbar_actions.focus_statusbar_action);
    for (statusbar_actions.navigation_actions) |action| try commands.registerAction(instantiation, action);
    for (terminal_actions.terminal_actions) |action| try commands.registerAction(instantiation, action);
    for (contributions.markdown) |action| try commands.registerEditorAction(instantiation, action);
    for (media_actions.zoom_actions) |action| try commands.registerEditorAction(instantiation, action);
    try commands.registerEditorAction(instantiation, media_actions.open_in_text_action);
    const search_contribution = @import("contrib/search/browser/search.contribution.zig");
    for (search_contribution.search_actions) |action| try commands.registerAction(instantiation, action);
    for (contributions.search_editor.actionDescriptors()) |action| try commands.registerAction(instantiation, action);
    for (search_contribution.result_actions) |action| try commands.registerAction(instantiation, action);
    for (@import("../editor/contrib/find/browser/findController.zig").editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/comment/browser/comment.zig").editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/linesOperations/browser/linesOperations.zig").editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/linesOperations/browser/linesOperations.zig").indent_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/insertFinalNewLine/browser/insertFinalNewLine.zig").editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/lineSelection/browser/lineSelection.zig").editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/multicursor/browser/multicursor.zig").editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/bracketMatching/browser/bracketMatching.zig").editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/smartSelect/browser/smartSelect.zig").editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/format/browser/formatActions.zig").editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/indentation/browser/indentation.zig").conversion_actions) |action| try commands.registerEditorAction(instantiation, action);
    try commands.registerEditorAction(instantiation, @import("../editor/contrib/wordHighlighter/browser/wordHighlighter.zig").trigger_action);
    for (@import("../editor/contrib/inPlaceReplace/browser/inPlaceReplace.zig").editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/indentation/browser/indentation.zig").reindent_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (@import("../editor/contrib/folding/browser/folding.zig").editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    for (sticky_actions.editor_actions) |action| try commands.registerEditorAction(instantiation, action);
    try commands.registerEditorAction(instantiation, @import("../editor/contrib/codelens/browser/codelensController.zig").show_lenses_action);
    try commands.registerAction(instantiation, @import("../editor/contrib/codelens/browser/codelens.zig").execute_provider_action);
    for (@import("../editor/contrib/wordHighlighter/browser/wordHighlighter.zig").navigation_actions) |action| try commands.registerEditorAction(instantiation, action);
}

/// The editor navigation actions come after the built-in extensions have
/// registered their own commands, preserving the terminal palette order.
pub fn registerEditorNavigationActions(commands: *CommandRegistry, instantiation: *InstantiationService, navigation: *@import("../editor/contrib/gotoSymbol/browser/goToCommands.zig").SymbolNavigationActionHost, quick_access: *@import("contrib/codeEditor/browser/quickaccess/gotoSymbolQuickAccess.zig").GotoSymbolQuickAccessProvider) !void {
    for (navigation.actionDescriptors()) |action| try commands.registerEditorAction(instantiation, action);
    try commands.registerEditorAction(instantiation, quick_access.actionDescriptor());
    try commands.registerEditorAction(instantiation, hover_actions.show_or_focus_hover_action);
}
