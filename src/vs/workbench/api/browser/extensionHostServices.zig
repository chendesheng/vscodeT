// Zig composition adapter for the main-thread extension host. Its runtime
// dependencies are the existing command, editor, configuration, notification,
// quick input, status and terminal services. The remaining cross-part actions
// are explicit, typed callbacks until those services own their implementation.
// Only this factory is parameterized by the concrete terminal window.
const std = @import("std");
const common = @import("builtinExtensionHost.zig");
const EditorGroups = @import("../../services/editor/common/editorGroupsService.zig");
const ContextKeyService = @import("../../../platform/contextkey/common/contextkey.zig").ContextKeyService;
const MarkerService = @import("../../../platform/markers/common/markerService.zig").MarkerService;
const TerminalInstance = @import("../../contrib/terminal/browser/terminalInstance.zig").TerminalInstance;
const SimpleBrowserManager = @import("../../../../extensions/simple-browser/src/simpleBrowserManager.zig").SimpleBrowserManager;
const INotificationService = @import("../../../platform/notification/common/notification.zig").INotificationService;
const QuickAccessService = @import("../../browser/quickaccess.zig").QuickAccessService;
const IViewsService = @import("../../services/views/common/viewsService.zig").IViewsService;
const WindowQueue = @import("../../../base/common/windowDispatch.zig").Queue;

pub const Services = struct {
    common: common.Services,
    window: *WindowQueue,
    quick_access: *QuickAccessService,
    notification: INotificationService,
    dialog: @import("../../../platform/dialogs/common/dialogs.zig").IDialogService,
    views: IViewsService,
    marker_service: ?*MarkerService,
    simple_browser: *SimpleBrowserManager,
    register_extension_configuration: *const fn (*anyopaque, std.json.Value, []const u8) void,
    context_keys: *const fn (*anyopaque) anyerror!*ContextKeyService,
    configuration_data: *const fn (*anyopaque, std.mem.Allocator) anyerror!std.json.Value,
    workspace_folder_path: *const fn (*anyopaque) ?[]const u8,
    focused_terminal: *const fn (*anyopaque) ?*TerminalInstance,
    has_editor_focus: *const fn (*anyopaque) bool,
    close_path: *const fn (*anyopaque, []const u8) anyerror!bool,
    close_active: *const fn (*anyopaque) anyerror!bool,
    split_active: *const fn (*anyopaque, EditorGroups.GroupDirection) anyerror!void,
    move_active_editor: *const fn (*anyopaque, []const u8, []const u8, usize) anyerror!void,
    activate_index: *const fn (*anyopaque, usize) anyerror!void,
    show_hover: *const fn (*anyopaque) anyerror!bool,
    goto_symbol: *const fn (*anyopaque) anyerror!bool,
    run_lsp_action: *const fn (*anyopaque, []const u8) anyerror!bool,

    /// Host wiring is explicit at composition. No extension actor receives
    /// the concrete window or can reach across into arbitrary shell fields.
    pub fn bind(host: anytype) Services {
        const Host = @TypeOf(host.*);
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
        return .{
            .common = host.builtinExtensionServices(),
            .window = &host.window_events,
            .quick_access = host.quick_access,
            .notification = host.notification_api,
            .dialog = host.dialog_api,
            .views = host.views_api,
            .marker_service = host.marker_service,
            .simple_browser = &host.simple_browser,
            .register_extension_configuration = Adapter.registerExtensionConfiguration,
            .context_keys = Adapter.contextKeys,
            .configuration_data = Adapter.configurationData,
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

    pub fn preferredSideBySideDirection(self: Services) EditorGroups.GroupDirection {
        const configuration = self.common.configuration(self.common.context);
        return EditorGroups.preferredSideBySideGroupDirection(if (configuration) |config| config.interface() else null);
    }
};
