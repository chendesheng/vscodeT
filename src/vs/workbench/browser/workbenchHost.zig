// Zig adaptation boundary for the port of workbench.ts. Native factories
// supply the mounted services without decorator reflection, DOM or src/tui
// dependencies. Workbench owns the startup, layout and lifecycle sequence.
const LifecycleService = @import("../services/lifecycle/common/lifecycleService.zig").LifecycleService;
const IContextKeyService = @import("../../platform/contextkey/common/contextkey.zig").IContextKeyService;
const ConfigurationService = @import("../services/configuration/browser/configurationService.zig").ConfigurationService;
const Tab = @import("parts/editor/editorPane.zig").Tab;
const GroupView = @import("parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("parts/editor/editorPart.zig").EditorPart(GroupView);
const CommandRegistry = @import("commands.zig").CommandRegistry;
const WorkbenchContributions = @import("../common/contributions.zig").WorkbenchContributions;
const NotificationService = @import("../services/notification/common/notificationService.zig").NotificationService;
const StatusbarService = @import("parts/statusbar/statusbarPart.zig").StatusbarService;
const Notifications = @import("parts/notifications/notificationsCommands.zig");
const Queue = @import("../../base/common/windowDispatch.zig").Queue;

/// Native composition hooks, not a feature service locator. All browser
/// Workbench ordering, layout registration, part creation, notifications
/// and lifecycle deadlines belong to Workbench.
pub const IWorkbenchHost = struct {
    context: *anyopaque,
    part: *EditorPart,
    commands: *CommandRegistry,
    contributions: *WorkbenchContributions,
    lifecycle: *LifecycleService,
    notification_service: *NotificationService,
    statusbar: *StatusbarService,
    window: *Queue,
    configuration: *const ?*ConfigurationService,
    notification_host: Notifications.NotificationsController.Host,
    register_services: *const fn (*anyopaque) anyerror!void,
    register_commands: *const fn (*anyopaque) anyerror!void,
    context_keys: *const fn (*anyopaque) anyerror!IContextKeyService,
    register_listeners: *const fn (*anyopaque) anyerror!void,
    restore_editors: *const fn (*anyopaque) anyerror!void,
    layout: *const fn (*anyopaque) void,
};
