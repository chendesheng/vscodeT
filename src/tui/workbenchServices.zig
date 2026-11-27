// Terminal-only composition adapters. The portable workbench, terminal and
// extension-host owners receive explicit typed services, not a generic host
// object. These adapters bind the native window's I/O and focus boundaries.
const std = @import("std");
const ui = @import("ui");
const TerminalWorkbench = @import("workbenchWindow.zig").TerminalWorkbench;
const terminal_service_mod = @import("../vs/workbench/contrib/terminal/browser/terminalService.zig");
const TerminalService = terminal_service_mod.TerminalService;
const TerminalInstance = terminal_service_mod.TerminalInstance;
const terminal_actions = @import("../vs/workbench/contrib/terminal/browser/terminalActions.zig");
const LanguageFeaturesService = @import("../vs/editor/common/services/languageFeaturesService.zig").LanguageFeaturesService;
const ConfigurationService = @import("../vs/workbench/services/configuration/browser/configurationService.zig").ConfigurationService;
const ContextKeyService = @import("../vs/platform/contextkey/common/contextkey.zig").ContextKeyService;
const EditorGroups = @import("../vs/workbench/services/editor/common/editorGroupsService.zig");
const ExtensionServices = @import("../vs/workbench/api/browser/extensionHostServices.zig").Services;

pub fn terminalActionServices(host: *TerminalWorkbench) terminal_actions.TerminalActionServices {
    const Host = TerminalWorkbench;
    const Adapter = struct {
        fn get(context: *anyopaque) *Host {
            return @ptrCast(@alignCast(context));
        }
        fn ensureService(context: *anyopaque) !*TerminalService {
            return get(context).ensureTerminalService();
        }
        fn revealPanel(context: *anyopaque) !void {
            try get(context).showTerminal();
        }
        fn revealEditor(context: *anyopaque, moved: bool) !void {
            try get(context).revealTerminalEditorMoved(moved);
        }
        fn hidePanel(context: *anyopaque) void {
            get(context).hidePanel();
        }
        fn panelActive(context: *anyopaque) bool {
            return get(context).terminalPanelActive();
        }
        fn panelRect(context: *anyopaque) ui.Rect {
            return get(context).geometry().panelRect();
        }
        fn panelFocused(context: *anyopaque) bool {
            return get(context).focus == .terminal;
        }
        fn editorFocused(context: *anyopaque) bool {
            return get(context).focus == .editor;
        }
        fn focusedTerminal(context: *anyopaque) ?*terminal_service_mod.TerminalInstance {
            return get(context).focusedTerminal();
        }
        fn focusPanel(context: *anyopaque) void {
            get(context).setFocus(.terminal);
        }
        fn layout(context: *anyopaque) void {
            get(context).layoutAll();
        }
        fn panelInstancesRemoved(context: *anyopaque, service: *TerminalService) !void {
            try get(context).onPanelTerminalsRemoved(service);
        }
    };
    return .{
        .context = host,
        .slot = &host.terminal_service,
        .configuration = &host.configuration,
        .configuration_api = host.configuration_api,
        .part = host.part,
        .factory = host.view_factory,
        .tabbed_view = &host.terminal_tabbed_view,
        .input = host.quick_access.inputService(),
        .dialogs = host.dialog_api,
        .close_host = host.closeEditorHost(),
        .ensure_service = Adapter.ensureService,
        .reveal_panel = Adapter.revealPanel,
        .reveal_editor = Adapter.revealEditor,
        .hide_panel = Adapter.hidePanel,
        .panel_active = Adapter.panelActive,
        .panel_rect = Adapter.panelRect,
        .panel_focused = Adapter.panelFocused,
        .editor_focused = Adapter.editorFocused,
        .focused_terminal = Adapter.focusedTerminal,
        .focus_panel = Adapter.focusPanel,
        .layout = Adapter.layout,
        .layout_service = host.layout_api,
        .panel_instances_removed = Adapter.panelInstancesRemoved,
    };
}

pub fn builtinExtensionServices(self: *TerminalWorkbench) @import("../vs/workbench/api/browser/builtinExtensionHost.zig").Services {
    const Host = struct {
        fn get(context: *anyopaque) *TerminalWorkbench {
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
        .window = &self.window_events,
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

pub fn extensionHostServices(host: *TerminalWorkbench) ExtensionServices {
    const Host = TerminalWorkbench;
    const Adapter = struct {
        fn get(context: *anyopaque) *Host {
            return @ptrCast(@alignCast(context));
        }
        fn registerExtensionConfiguration(context: *anyopaque, manifest: std.json.Value, id: []const u8) void {
            get(context).registerExtensionConfiguration(manifest, id);
        }
        fn contextKeys(context: *anyopaque) !*ContextKeyService {
            return get(context).ensureContextKeys();
        }
        fn configurationData(context: *anyopaque, allocator: std.mem.Allocator) !std.json.Value {
            return get(context).configurationData(allocator);
        }
        fn workspaceFolderPath(context: *anyopaque) ?[]const u8 {
            return get(context).workspaceFolderPath();
        }
        fn focusedTerminal(context: *anyopaque) ?*TerminalInstance {
            return get(context).focusedTerminal();
        }
        fn hasEditorFocus(context: *anyopaque) bool {
            return get(context).focus == .editor;
        }
        fn closePath(context: *anyopaque, path: []const u8) !bool {
            return get(context).closePath(path);
        }
        fn closeActive(context: *anyopaque) !bool {
            return get(context).closeActive();
        }
        fn splitActive(context: *anyopaque, direction: EditorGroups.GroupDirection) !void {
            try get(context).splitActiveInDirection(direction);
        }
        fn moveActiveEditor(context: *anyopaque, to: []const u8, by: []const u8, value: usize) !void {
            try get(context).moveActiveEditor(to, by, value);
        }
        fn activateIndex(context: *anyopaque, index: usize) !void {
            try get(context).activateIndex(index);
        }
        fn showHover(context: *anyopaque) !bool {
            return get(context).showHover();
        }
        fn gotoSymbol(context: *anyopaque) !bool {
            return get(context).gotoSymbolInEditor();
        }
        fn runLspAction(context: *anyopaque, id: []const u8) !bool {
            return get(context).runLspAction(id);
        }
    };
    var common = host.builtinExtensionServices();
    // The Node host starts after the workbench service registrations, unlike
    // the compiled extensions that are constructed during window startup.
    common.editors = host.editors;
    return .{
        .common = common,
        .window = &host.window_events,
        .file_service = host.file_service_api,
        .language_status = host.language_status_api,
        .text_files = &host.text_file_service,
        .quick_access = host.quick_access,
        .notification = host.notification_api,
        .dialog = host.dialog_api,
        .views = host.views_api,
        .marker_service = host.marker_service,
        .quick_diff = host.scm.quick_diff_api.?.*,
        .quick_diff_models = host.scm.quick_diff_model_api.?.*,
        .text_model_service = host.text_model_api,
        .bulk_edit = host.bulk_edit_api,
        .model_service = host.model_service_api,
        .simple_browser = &host.simple_browser,
        .register_extension_configuration = Adapter.registerExtensionConfiguration,
        .context_keys = Adapter.contextKeys,
        .configuration_data = Adapter.configurationData,
        .workspace = host.workspace,
        .workspace_folder_path = Adapter.workspaceFolderPath,
        .focused_terminal = Adapter.focusedTerminal,
        .has_editor_focus = Adapter.hasEditorFocus,
        .close_path = Adapter.closePath,
        .close_active = Adapter.closeActive,
        .split_active = Adapter.splitActive,
        .move_active_editor = Adapter.moveActiveEditor,
        .activate_index = Adapter.activateIndex,
        .show_hover = Adapter.showHover,
        .goto_symbol = Adapter.gotoSymbol,
        .run_lsp_action = Adapter.runLspAction,
    };
}
