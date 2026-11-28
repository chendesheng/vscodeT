// Port of the portable startup and lifecycle of
// src/vs/workbench/browser/workbench.ts (pinned VS Code 1.147.0).
// Native service instances are supplied explicitly by the terminal window;
// Zig does not use decorator reflection. Layout uses the registered cell
// parts instead of a browser DOM grid. Floating/auxiliary windows, browser
// font metrics/aliasing, ARIA live regions/accessible view, traffic lights
// and browser-managed selection/IME have no terminal implementation. The
// portable notification handlers are created in the upstream order.
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
const Emitter = @import("../../base/common/event.zig").Emitter;
const async = @import("../../base/common/async.zig");
const WindowTimer = async.WindowTimer;
const IContextKeyService = @import("../../platform/contextkey/common/contextkey.zig").IContextKeyService;
const Notifications = @import("parts/notifications/notificationsCommands.zig");

const host_service = @import("../services/host/browser/host.zig");
const storage_service = @import("../../platform/storage/common/storage.zig");
const dialogs = @import("../../platform/dialogs/common/dialogs.zig");
const SignalSubscription = @import("../../base/common/event.zig").SignalSubscription;
const Host = @import("workbenchHost.zig").IWorkbenchHost;

pub const IWorkbenchOptions = struct {
    /// Class IDs in the terminal document stylesheet.
    extra_classes: []const u16 = &.{},
    reset_layout: bool = false,
    initial_user_settings_paths: []const []const u8 = &.{},
    profile_storage_path: ?[]const u8 = null,
    application_storage_path: ?[]const u8 = null,
};

pub const Workbench = struct {
    allocator: Allocator,
    layout: Layout,
    editor_factory_registry: @import("../common/editor/editorFactory.zig").EditorFactoryRegistry,
    startup_window: ?struct { parent: *ui.Node, options: IWorkbenchOptions, has_previous_state: bool },
    instantiation: InstantiationService = undefined,
    instantiation_ready: bool = false,
    host: Host = undefined,
    layout_api: layout_service.IWorkbenchLayoutService = undefined,
    lifecycle_api: lifecycle_mod.ILifecycleService = undefined,
    context_keys: IContextKeyService = undefined,
    host_service_api: host_service.IHostService = undefined,
    storage_api: storage_service.IStorageService = undefined,
    on_will_shutdown: Emitter(lifecycle_mod.WillShutdownEvent),
    on_did_shutdown: Emitter(void),
    listeners: [6]?SignalSubscription = @splat(null),
    restore_timer: ?*WindowTimer = null,
    restore_state_ready: async.Barrier = .{},
    saved_layout: ?Layout.WorkspaceState = null,
    notification_controller: ?*Notifications.NotificationsController = null,

    pub fn init(allocator: Allocator, parent: *ui.Node, options: IWorkbenchOptions, has_previous_state: bool) Workbench {
        var layout = Layout.init(allocator);
        layout.reset_layout = options.reset_layout;
        return .{
            .allocator = allocator,
            .layout = layout,
            .editor_factory_registry = .init(allocator),
            .on_will_shutdown = .init(allocator),
            .on_did_shutdown = .init(allocator),
            .startup_window = .{ .parent = parent, .options = options, .has_previous_state = has_previous_state },
        };
    }

    pub fn startup(self: *Workbench, services: *ServiceCollection, host: Host) !*InstantiationService {
        const window = self.startup_window orelse return error.WorkbenchAlreadyStarted;
        self.startup_window = null;
        self.host = host;
        try self.initServices(services);
        try self.instantiation.invokeFunction(startWorkbench, .{ self, window.parent, window.options, window.has_previous_state });
        return &self.instantiation;
    }

    fn startWorkbench(accessor: ServicesAccessor, self: *Workbench, parent: *ui.Node, options: IWorkbenchOptions, has_previous_state: bool) !void {
        const host = self.host;
        // Layout
        try self.layout.initLayout(host.part);
        // Registries
        try host.register_commands(host.context);
        try @import("../workbench.common.main.zig").registerMenus(&host.commands.menus);
        try host.contributions.start(accessor);
        try (host.editor_factory_registry orelse &self.editor_factory_registry).start(accessor);
        // Context Keys
        self.context_keys = try host.context_keys(host.context);
        // Listeners, Parts and Notifications
        try self.registerListeners(accessor);
        try self.renderWorkbench(parent, options);
        // Workbench Layout
        try self.layout.createWorkbenchLayout();
        host.layout(host.context);
        // Restore
        try self.restore(has_previous_state);
    }

    fn initServices(self: *Workbench, services: *ServiceCollection) !void {
        self.layout_api = self.layout.interface();
        _ = try services.set(layout_service.layout_service_id, &self.layout_api);
        try self.host.register_services(self.host.context);
        try self.instantiation.init(self.allocator, services);
        self.instantiation_ready = true;
        self.lifecycle_api = try self.instantiation.invokeFunction(setServicesReady, .{});
    }

    fn setServicesReady(accessor: ServicesAccessor) !lifecycle_mod.ILifecycleService {
        const lifecycle = (try accessor.get(lifecycle_mod.lifecycle_service_id)).*;
        try lifecycle.setPhase(.Ready);
        return lifecycle;
    }

    fn registerListeners(self: *Workbench, accessor: ServicesAccessor) !void {
        self.listeners[0] = try self.lifecycle_api.on_will_shutdown.listenDisposable(self, onWillShutdown);
        self.listeners[1] = try self.lifecycle_api.on_did_shutdown.listenDisposable(self, onDidShutdown);
        self.host_service_api = (try accessor.get(host_service.host_service_id)).*;
        self.storage_api = (try accessor.get(storage_service.storage_service_id)).*;
        self.listeners[2] = try self.host_service_api.on_did_change_focus.listenDisposable(self, onWindowFocus);
        const dialog = try accessor.get(dialogs.dialog_service_id);
        self.listeners[3] = try dialog.on_will_show_dialog.listenDisposable(self, onWillShowDialog);
        self.listeners[4] = try dialog.on_did_show_dialog.listenDisposable(self, onDidShowDialog);
        try self.host.register_listeners(self.host.context);
    }

    fn onWillShutdown(event: lifecycle_mod.WillShutdownEvent, self: *Workbench) !void {
        try self.on_will_shutdown.fire(event);
    }

    fn onDidShutdown(_: void, self: *Workbench) !void {
        try self.on_did_shutdown.fire({});
    }

    fn onWindowFocus(focused: bool, self: *Workbench) !void {
        if (!focused) self.storage_api.flush(.none) catch |err|
            std.log.scoped(.workbench).err("failed to flush state: {s}", .{@errorName(err)});
    }

    fn onWillShowDialog(_: void, self: *Workbench) !void {
        if (self.layout.main_container) |main| try main.addClass(editor_css.workbench.Class.modal_dialog_visible);
    }

    fn onDidShowDialog(_: void, self: *Workbench) !void {
        if (self.layout.main_container) |main| main.removeClass(editor_css.workbench.Class.modal_dialog_visible);
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
        const panel_side = Layout.panelPositionClass(self.layout_api.getPanelPosition());
        inline for (.{
            .{ .activitybar, "none", &[_]Class{ .activitybar, side } },
            .{ .sidebar, "none", &[_]Class{ .sidebar, side } },
            .{ .editor, "main", &[_]Class{.editor} },
            .{ .panel, "none", &[_]Class{ .panel, .basepanel, panel_side } },
            .{ .statusbar, "status", &[_]Class{.statusbar} },
        }) |description| {
            const container = try createPart(main, description[0], description[1], description[2]);
            const part = try self.layout.getPart(description[0]);
            try part.create(container);
        }
        try self.createNotificationsHandlers();
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
        try controller.attachHostService(self.host_service_api);
        _ = try self.instantiation.services.set(Notifications.controller_id, controller);
        try Notifications.registerNotificationCommands(host.commands, &self.instantiation);
        self.notification_controller = controller;
    }

    fn restore(self: *Workbench, has_previous_state: bool) !void {
        self.listeners[5] = try self.lifecycle_api.on_will_shutdown.listenDisposable(self, stopRestoration);
        if (has_previous_state) {
            try self.host.restore_editors(self.host.context);
            self.host.layout(self.host.context);
        } else try self.host.part.when_restored.open(self.allocator);
        // Native storage/profile initialization completes asynchronously
        // after startup. Await that input before restoring layout parts.
        try self.restore_state_ready.wait(self.allocator, .{ .context = self, .run = onRestoreStateReady });
    }

    pub fn provideRestoreState(self: *Workbench, timer: *WindowTimer, saved: ?Layout.WorkspaceState) !void {
        if (self.startup_window != null or self.restore_state_ready.is_open or self.host.lifecycle.will_shutdown) return error.WorkbenchAlreadyRestoring;
        self.restore_timer = timer;
        self.saved_layout = saved;
        try self.restore_state_ready.open(self.allocator);
    }

    fn onRestoreStateReady(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const restoring = self.layout.restoreParts(self.saved_layout, &self.host.part.when_restored);
        try self.layout.when_ready.wait(self.allocator, .{ .context = self, .run = onLayoutReady });
        restoring catch |err| std.log.scoped(.workbench).err("restore failed: {s}", .{@errorName(err)});
    }

    fn stopRestoration(_: lifecycle_mod.WillShutdownEvent, self: *Workbench) !void {
        self.cancelRestoreTimer();
    }

    pub fn cancelRestoreTimer(self: *Workbench) void {
        self.restore_state_ready.cancelWait(.{ .context = self, .run = onRestoreStateReady });
        if (self.restore_timer) |timer| {
            timer.callback = null;
            self.layout.when_ready.cancelWait(.{ .context = self, .run = onLayoutReady });
            self.layout.when_restored.cancelWait(.{ .context = self, .run = onLayoutRestored });
        }
        self.restore_timer = null;
    }

    fn onLayoutReady(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const callback = lifecycle_mod.Continuation{ .context = self, .run = onLayoutRestored };
        const timer = self.restore_timer orelse return;
        timer.setTimeout(2000, callback);
        try self.layout.when_restored.wait(self.allocator, callback);
    }

    fn onLayoutRestored(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        if (self.restore_timer == null or self.lifecycle_api.phase().reached(.Restored)) return;
        defer if (self.restore_timer) |timer| timer.setTimeout(2500, .{ .context = self, .run = scheduleEventually });
        try self.lifecycle_api.setPhase(.Restored);
        if (self.notification_controller) |controller| try controller.toasts.start();
    }

    fn scheduleEventually(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        if (self.restore_timer) |timer| timer.runWhenIdle(2500, .{ .context = self, .run = onWindowIdle });
    }

    fn onWindowIdle(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        try self.lifecycle_api.setPhase(.Eventually);
    }

    pub fn disposeListeners(self: *Workbench) void {
        self.cancelRestoreTimer();
        for (&self.listeners) |*subscription| {
            if (subscription.*) |listener| listener.dispose();
            subscription.* = null;
        }
    }

    pub fn disposeNotifications(self: *Workbench) void {
        if (self.notification_controller) |controller| controller.deinit();
        self.notification_controller = null;
    }

    pub fn disposeInstantiation(self: *Workbench) void {
        if (!self.instantiation_ready) return;
        self.instantiation_ready = false;
        (self.host.editor_factory_registry orelse &self.editor_factory_registry).stop(&self.instantiation);
        self.instantiation.deinit();
    }

    pub fn deinit(self: *Workbench) void {
        self.disposeListeners();
        self.disposeNotifications();
        self.disposeInstantiation();
        self.editor_factory_registry.deinit();
        self.restore_state_ready.deinit(self.allocator);
        self.on_will_shutdown.deinit();
        self.on_did_shutdown.deinit();
        self.layout.deinit();
    }
};
