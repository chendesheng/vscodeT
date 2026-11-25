// Port of the portable startup and lifecycle of
// src/vs/workbench/browser/workbench.ts (pinned VS Code 1.147.0).
// Native service instances are supplied explicitly by the terminal window;
// Zig does not use decorator reflection. Layout uses the registered cell
// parts instead of a browser DOM grid. Auxiliary windows, browser font
// aliasing/metrics, DOM accessibility announcements, and layout traffic
// lights have no terminal implementation. The portable notification
// center, toasts and status handlers are created in the upstream order.
const std = @import("std");
const ui = @import("ui");
const Allocator = std.mem.Allocator;
const workbench_layout = @import("layout.zig");
const Layout = workbench_layout.Layout;
const layout_service = @import("../services/layout/browser/layoutService.zig");
const editor_css = @import("../../editor/browser/editorCss.zig");
const ServiceCollection = @import("../../platform/instantiation/common/serviceCollection.zig").ServiceCollection;
const InstantiationService = @import("../../platform/instantiation/common/instantiationService.zig").InstantiationService;
const ServicesAccessor = @import("../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const lifecycle_mod = @import("../services/lifecycle/common/lifecycle.zig");
const LifecycleService = @import("../services/lifecycle/common/lifecycleService.zig").LifecycleService;
const Emitter = @import("../../base/common/event.zig").Emitter;
const WindowTimer = @import("../../base/common/async.zig").WindowTimer;
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

pub const IWorkbenchOptions = struct {
    /// Class IDs in the terminal document stylesheet.
    extra_classes: []const u16 = &.{},
    reset_layout: bool = false,
};

/// Native composition hooks, not a feature service locator. All browser
/// Workbench ordering, layout registration, part creation, notifications
/// and lifecycle deadlines belong to Workbench.
pub const Host = struct {
    context: *anyopaque,
    part: *EditorPart,
    commands: *CommandRegistry,
    contributions: *WorkbenchContributions,
    lifecycle: *LifecycleService,
    will_shutdown: *Emitter(lifecycle_mod.WillShutdownEvent),
    did_shutdown: *Emitter(void),
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

pub const Workbench = struct {
    allocator: Allocator,
    layout: Layout,
    startup_window: ?struct { parent: *ui.Node, options: IWorkbenchOptions, has_previous_state: bool },
    services: *ServiceCollection = undefined,
    instantiation: InstantiationService = undefined,
    instantiation_ready: bool = false,
    host: Host = undefined,
    layout_api: layout_service.IWorkbenchLayoutService = undefined,
    lifecycle_api: lifecycle_mod.ILifecycleService = undefined,
    context_keys: IContextKeyService = undefined,
    restore_timer: ?*WindowTimer = null,
    notification_controller: ?*Notifications.NotificationsController = null,

    pub fn init(allocator: Allocator, parent: *ui.Node, options: IWorkbenchOptions, has_previous_state: bool) Workbench {
        return .{
            .allocator = allocator,
            .layout = Layout.init(allocator),
            .startup_window = .{ .parent = parent, .options = options, .has_previous_state = has_previous_state },
        };
    }

    pub fn startup(self: *Workbench, services: *ServiceCollection, host: Host) !*InstantiationService {
        const window = self.startup_window orelse return error.WorkbenchAlreadyStarted;
        self.startup_window = null;
        self.services = services;
        self.host = host;
        try self.initServices();
        try self.instantiation.invokeFunction(startWorkbench, .{ self, window.parent, window.options });
        if (window.has_previous_state) {
            try host.restore_editors(host.context);
            host.layout(host.context);
        } else try host.part.when_restored.open(self.allocator);
        return &self.instantiation;
    }

    fn startWorkbench(accessor: ServicesAccessor, self: *Workbench, parent: *ui.Node, options: IWorkbenchOptions) !void {
        const host = self.host;
        // Layout
        try self.layout.initLayout(host.part);
        // Registries
        try host.register_commands(host.context);
        try @import("../workbench.common.main.zig").registerMenus(&host.commands.menus);
        try host.contributions.start(accessor);
        // Context Keys
        self.context_keys = try host.context_keys(host.context);
        // Listeners, Parts and Notifications
        try self.registerListeners();
        try self.renderWorkbench(parent, options);
        try self.createNotificationsHandlers();
        // Workbench Layout
        try self.layout.createWorkbenchLayout();
        host.layout(host.context);
    }

    fn initServices(self: *Workbench) !void {
        self.layout_api = self.layout.interface();
        _ = try self.services.set(layout_service.layout_service_id, &self.layout_api);
        try self.host.register_services(self.host.context);
        try self.instantiation.init(self.allocator, self.services);
        self.instantiation_ready = true;
        self.lifecycle_api = try self.instantiation.invokeFunction(setServicesReady, .{});
    }

    fn setServicesReady(accessor: ServicesAccessor) !lifecycle_mod.ILifecycleService {
        const lifecycle = (try accessor.get(lifecycle_mod.lifecycle_service_id)).*;
        try lifecycle.setPhase(.Ready);
        return lifecycle;
    }

    fn registerListeners(self: *Workbench) !void {
        _ = try self.lifecycle_api.on_will_shutdown.listen(self, onWillShutdown);
        _ = try self.lifecycle_api.on_did_shutdown.listen(self, onDidShutdown);
        try self.host.register_listeners(self.host.context);
    }

    fn onWillShutdown(event: lifecycle_mod.WillShutdownEvent, self: *Workbench) !void {
        try self.host.will_shutdown.fire(event);
    }

    fn onDidShutdown(_: void, self: *Workbench) !void {
        try self.host.did_shutdown.fire({});
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

    fn createNotificationsHandlers(self: *Workbench) !void {
        const host = self.host;
        const controller = try Notifications.NotificationsController.create(self.allocator, host.notification_service, host.statusbar, host.window, self.context_keys, host.notification_host);
        errdefer controller.deinit();
        try controller.attachConfiguration(host.configuration.*);
        _ = try self.services.set(Notifications.controller_id, controller);
        try Notifications.registerNotificationCommands(host.commands, &self.instantiation);
        self.notification_controller = controller;
    }

    pub fn restore(self: *Workbench, timer: *WindowTimer, saved: ?Layout.WorkspaceState) !void {
        if (self.restore_timer != null or self.host.lifecycle.will_shutdown) return error.WorkbenchAlreadyRestoring;
        _ = try self.host.lifecycle.on_will_shutdown.listen(self, stopRestoration);
        self.restore_timer = timer;
        const restoring = self.layout.restoreParts(saved, &self.host.part.when_restored);
        try self.layout.when_ready.wait(self.allocator, .{ .context = self, .run = onLayoutReady });
        try restoring;
    }

    fn stopRestoration(_: lifecycle_mod.WillShutdownEvent, self: *Workbench) !void {
        self.cancelRestoreTimer();
    }

    pub fn cancelRestoreTimer(self: *Workbench) void {
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
        if (self.restore_timer == null or self.lifecycle_api.phase().reached(.Restored)) return;
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

    pub fn disposeNotifications(self: *Workbench) void {
        if (self.notification_controller) |controller| controller.deinit();
        self.notification_controller = null;
    }

    pub fn disposeInstantiation(self: *Workbench) void {
        if (!self.instantiation_ready) return;
        self.instantiation_ready = false;
        self.instantiation.deinit();
    }

    pub fn deinit(self: *Workbench) void {
        self.cancelRestoreTimer();
        self.disposeNotifications();
        self.disposeInstantiation();
        self.layout.deinit();
    }
};
