// Explicit native-adapted service contract for the main-thread extension host. Its runtime
// dependencies are the existing command, editor, configuration, notification,
// quick input, status and terminal services. The remaining cross-part actions
// are explicit, typed callbacks until those services own their implementation.
// The terminal composition adapter constructs this service contract; portable
// code does not depend on the concrete native window type.
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

    pub fn preferredSideBySideDirection(self: Services) EditorGroups.GroupDirection {
        const configuration = self.common.configuration(self.common.context);
        return EditorGroups.preferredSideBySideGroupDirection(if (configuration) |config| config.interface() else null);
    }
};
