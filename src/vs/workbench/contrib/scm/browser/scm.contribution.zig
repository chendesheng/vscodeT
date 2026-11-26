// Port of the SCM view contribution registrations in
// `src/vs/workbench/contrib/scm/browser/scm.contribution.ts`.
// The terminal uses explicit construction rather than SyncDescriptor and
// singleton decorators. The contribution owns the service and the Changes,
// Graph and quick-diff controllers, while the sidebar hosts its view panes.
// The native extension supplies ISCMProvider and QuickDiffProvider objects;
// the active repository follows SCMViewService. Explicit repository-list
// visibility/sorting and working-set controllers remain unported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const scm = @import("../common/scm.zig");
const SCMService = @import("../common/scmService.zig").SCMService;
const SCMViewService = @import("scmViewService.zig").SCMViewService;
const quick_diff = @import("../common/quickDiffService.zig");
const QuickDiffWorkbenchController = @import("quickDiffDecorator.zig").QuickDiffWorkbenchController;
const scm_view = @import("scmViewPane.zig");
const scm_history = @import("scmHistoryViewPane.zig");
const Storage = @import("../../../../platform/storage/common/storage.zig").InMemoryStorageService;
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;
const EditorService = @import("../../../services/editor/browser/editorService.zig").EditorService;
const ThemeColors = @import("../../../browser/themeColors.zig").ThemeColors;
const SCMActiveRepositoryController = @import("activity.zig").SCMActiveRepositoryController;
const ActivityService = @import("../../../services/activity/browser/activityService.zig").ActivityService;
const WindowQueue = @import("../../../../base/common/windowDispatch.zig").Queue;
const quick_models = @import("quickDiffModel.zig");

const SidebarPart = @import("../../../browser/parts/sidebar/sidebarPart.zig").SidebarPart;
const ViewDescriptorService = @import("../../../services/views/browser/viewDescriptorService.zig").ViewDescriptorService;
const ViewContainerModel = @import("../../../services/views/common/viewContainerModel.zig").ViewContainerModel;
const pane_container = @import("../../../browser/parts/views/viewPaneContainer.zig");

pub const SCMContribution = struct {
    allocator: Allocator,
    view_model: ?*ViewContainerModel = null,
    container: ?*pane_container.ViewPaneContainer = null,
    sidebar: ?*SidebarPart = null,
    view_descriptors: ?*ViewDescriptorService = null,
    service: ?*SCMService = null,
    service_api: ?*scm.ISCMService = null,
    view_service: ?*SCMViewService = null,
    view_service_api: ?*scm.ISCMViewService = null,
    active_repository_listener: ?@import("../../../../base/common/event.zig").SignalSubscription = null,
    storage: ?*Storage = null,
    quick_diff_service: ?*quick_diff.QuickDiffService = null,
    quick_diff_api: ?*quick_diff.IQuickDiffService = null,
    quick_diff_model_service: ?*quick_models.QuickDiffModelService = null,
    quick_diff_model_api: ?*quick_models.IQuickDiffModelService = null,
    provider_bindings: std.ArrayList(ProviderBinding) = .empty,
    resource_events: ?*@import("../../../../base/common/event.zig").Emitter(void) = null,

    quick_diff_controller: ?*QuickDiffWorkbenchController = null,
    changes: ?*scm_view.SCMViewPane = null,
    history: ?*scm_history.SCMHistoryViewPane = null,
    activity: ?*SCMActiveRepositoryController = null,
    configuration_service: ?*ConfigurationService = null,
    configuration_listener: ?usize = null,

    const ProviderBinding = struct {
        repository: *scm.ISCMRepository,
        quick_registrations: []quick_diff.IDisposable,
        resource_listener: @import("../../../../base/common/event.zig").SignalSubscription,
        provider_listener: ?@import("../../../../base/common/event.zig").SignalSubscription,

        fn dispose(self: ProviderBinding, allocator: Allocator) void {
            self.resource_listener.dispose();
            if (self.provider_listener) |listener| listener.dispose();
            for (self.quick_registrations) |registration| registration.dispose();
            allocator.free(self.quick_registrations);
            self.repository.dispose();
        }
    };

    pub fn init(allocator: Allocator) SCMContribution {
        return .{ .allocator = allocator };
    }

    /// The SCM service has window lifetime, including before any provider is
    /// registered. Source resolvers can subscribe while extensions activate.
    pub fn ensureService(self: *SCMContribution) !*scm.ISCMService {
        if (self.service_api) |api| return api;
        const service = try self.allocator.create(SCMService);
        errdefer self.allocator.destroy(service);
        service.* = SCMService.init(self.allocator);
        errdefer service.deinit();
        const api = try self.allocator.create(scm.ISCMService);
        api.* = service.interface();
        self.service = service;
        self.service_api = api;
        return api;
    }

    pub fn ensureViewService(self: *SCMContribution, editors: @import("../../../services/editor/common/editorService.zig").IEditorService) !*scm.ISCMViewService {
        if (self.view_service_api) |api| return api;
        const service = try self.ensureService();
        const view = try SCMViewService.create(self.allocator, service.*, editors);
        errdefer view.destroy();
        const api = try self.allocator.create(scm.ISCMViewService);
        api.* = view.interface();
        self.view_service = view;
        self.view_service_api = api;
        return api;
    }

    pub fn ensureQuickDiffServices(self: *SCMContribution, window: *WindowQueue, resolver: @import("../../../../editor/common/services/resolverService.zig").ITextModelService, storage: ?*Storage) !*quick_models.IQuickDiffModelService {
        if (self.quick_diff_model_api) |api| return api;
        const a = self.allocator;
        const service = try a.create(quick_diff.QuickDiffService);
        errdefer a.destroy(service);
        service.* = quick_diff.QuickDiffService.init(a, storage);
        errdefer service.deinit();
        const quick_api = try a.create(quick_diff.IQuickDiffService);
        errdefer a.destroy(quick_api);
        quick_api.* = service.interface();
        const models = try a.create(quick_models.QuickDiffModelService);
        errdefer a.destroy(models);
        models.* = .init(a, quick_api.*, window, resolver);
        errdefer models.deinit();
        const api = try a.create(quick_models.IQuickDiffModelService);
        api.* = models.interface();
        self.quick_diff_service = service;
        self.quick_diff_api = quick_api;
        self.quick_diff_model_service = models;
        self.quick_diff_model_api = api;
        return api;
    }

    pub const Options = struct {
        editors: EditorService,
        text_model_service: @import("../../../../editor/common/services/resolverService.zig").ITextModelService,
        view_factory: ?@import("../../../../editor/browser/widget/codeEditor/terminalEditorView.zig").EditorViewFactory = null,
        quick_diff_menu: ?@import("quickDiffWidget.zig").MenuHost = null,
        activity_service: *ActivityService,
        statusbar_service: *@import("../../../browser/parts/statusbar/statusbarPart.zig").StatusbarService,
        window: *WindowQueue,
        configuration: ?*ConfigurationService,
        changes_host: scm_view.Host,
        history_host: scm_history.Host,
        quick_input: *@import("../../../../platform/quickinput/browser/quickInputService.zig").QuickInputService,
    };

    /// Mount the registered SCM container after its provider becomes active.
    pub fn attachContainer(self: *SCMContribution, sidebar: *SidebarPart, descriptors: *ViewDescriptorService, panes: []const pane_container.Pane, has_history: bool) !void {
        if (self.container != null) return error.ContainerAlreadyExists;
        const registration = descriptors.getViewContainerById("scm") orelse return error.UnknownViewContainer;
        const model = try self.allocator.create(ViewContainerModel);
        errdefer self.allocator.destroy(model);
        model.* = ViewContainerModel.init(self.allocator, .{ .id = registration.id, .title = registration.title, .icon = "" });
        errdefer model.deinit();
        descriptors.setViewAvailable("changes", true);
        descriptors.setViewAvailable("graph", has_history);
        errdefer {
            descriptors.setViewAvailable("changes", false);
            descriptors.setViewAvailable("graph", false);
        }
        const container = try sidebar.createViewPaneContainer(descriptors, model, panes);
        self.sidebar = sidebar;
        self.view_descriptors = descriptors;
        self.container = container;
        self.view_model = model;
        container.setContainerMenuAction(.{ .id = "workbench.scm.action.showMenu", .label = "More Actions", .glyph = '…' });
    }

    pub fn attachProvider(self: *SCMContribution, provider: *scm.ISCMProvider, quick_providers: []const *quick_diff.QuickDiffProvider, options: Options) !void {
        const allocator = self.allocator;
        if (self.changes != null) return error.ProviderAlreadyExists;
        errdefer self.detachProvider();
        const api = try self.ensureService();
        const scm_views = self.view_service_api orelse if (options.changes_host.editor_service) |editors| try self.ensureViewService(editors) else return error.SCMViewServiceUnavailable;
        const storage = try allocator.create(Storage);
        storage.* = Storage.init(allocator);
        self.storage = storage;
        _ = try self.ensureQuickDiffServices(options.window, options.text_model_service, null);
        const quick_service = self.quick_diff_service.?;
        const models = self.quick_diff_model_service.?;
        const resource_events = try allocator.create(@import("../../../../base/common/event.zig").Emitter(void));
        resource_events.* = .init(allocator);
        self.resource_events = resource_events;
        self.activity = try SCMActiveRepositoryController.create(allocator, api.*, scm_views.*, resource_events, options.activity_service, options.statusbar_service, options.configuration);
        try models.setRepositoryResources(resource_events);
        try self.registerProvider(provider, quick_providers);

        const controller = try allocator.create(QuickDiffWorkbenchController);
        controller.* = QuickDiffWorkbenchController.init(allocator, quick_service.interface(), models);
        self.quick_diff_controller = controller;
        controller.view_factory = options.view_factory;
        controller.quick_input = options.quick_input;
        controller.menu_host = options.quick_diff_menu;
        try controller.start(options.editors, options.configuration);

        const view = try allocator.create(scm_view.SCMViewPane);
        view.* = scm_view.SCMViewPane.init(allocator, api, options.changes_host);
        view.scm_view_service = scm_views.*;
        self.changes = view;

        const history = try scm_history.SCMHistoryViewPane.init(allocator, options.history_host, storage);
        self.history = history;
        history.quick_input = options.quick_input;
        self.active_repository_listener = try scm_views.on_did_change_active_repository.listenDisposable(self, onActiveRepositoryChanged);
        try self.setViewConfiguration(options.configuration);
        self.applyProviderState();
    }

    /// All repositories share the same views and Quick Diff model collection,
    /// with independently disposable provider registrations.
    pub fn registerProvider(self: *SCMContribution, provider: *scm.ISCMProvider, quick_providers: []const *quick_diff.QuickDiffProvider) !void {
        const api = try self.ensureService();
        const quick_service = self.quick_diff_service orelse return error.QuickDiffUnavailable;
        const repository = try api.registerSCMProvider(provider);
        errdefer repository.dispose();
        const registrations = try self.allocator.alloc(quick_diff.IDisposable, quick_providers.len);
        @memset(registrations, quick_diff.IDisposable.none);
        errdefer {
            for (registrations) |registration| registration.dispose();
            self.allocator.free(registrations);
        }
        for (quick_providers, registrations) |quick, *registration| registration.* = try quick_service.addQuickDiffProvider(quick);
        const resource_listener = try provider.on_did_change_resources.listenDisposable(self, onRepositoryResourcesChanged);
        errdefer resource_listener.dispose();
        const provider_listener = if (provider.on_did_change) |metadata| try metadata.listenDisposable(self, onProviderChanged) else null;
        errdefer if (provider_listener) |listener| listener.dispose();
        try self.provider_bindings.append(self.allocator, .{ .repository = repository, .quick_registrations = registrations, .resource_listener = resource_listener, .provider_listener = provider_listener });
        self.applyProviderState();
    }

    pub fn unregisterProvider(self: *SCMContribution, provider: *scm.ISCMProvider) void {
        for (self.provider_bindings.items, 0..) |binding, index| {
            if (binding.repository.provider != provider) continue;
            _ = self.provider_bindings.orderedRemove(index);
            binding.dispose(self.allocator);
            self.applyProviderState();
            return;
        }
    }

    fn onRepositoryResourcesChanged(_: void, self: *SCMContribution) !void {
        if (self.resource_events) |events| try events.fire({});
        self.applyProviderState();
    }

    pub fn detachConfiguration(self: *SCMContribution) void {
        if (self.configuration_listener) |listener| self.configuration_service.?.unlistenConfigurationChange(listener);
        self.configuration_listener = null;
        self.configuration_service = null;
        if (self.activity) |activity| activity.detachConfiguration();
        if (self.quick_diff_controller) |controller| controller.detachConfiguration();
    }

    pub fn setConfiguration(self: *SCMContribution, service: ?*ConfigurationService) !void {
        if (self.activity) |activity| try activity.setConfiguration(service);
        if (self.quick_diff_controller) |controller| try controller.setConfiguration(service);
        try self.setViewConfiguration(service);
    }

    fn setViewConfiguration(self: *SCMContribution, service: ?*ConfigurationService) !void {
        if (self.configuration_listener) |listener| self.configuration_service.?.unlistenConfigurationChange(listener);
        self.configuration_service = service;
        self.configuration_listener = null;
        if (service) |config| self.configuration_listener = try config.listenConfigurationChange(self, onDidChangeConfiguration);
        self.applyViewConfiguration();
    }

    fn onDidChangeConfiguration(change: configuration.Change, self: *SCMContribution) !void {
        if (configuration.affectsConfiguration(change, "scm") or configuration.affectsConfiguration(change, "git") or
            configuration.affectsConfiguration(change, "explorer.decorations") or configuration.affectsConfiguration(change, "workbench.tree.renderIndentGuides"))
            self.applyViewConfiguration();
    }

    fn applyViewConfiguration(self: *SCMContribution) void {
        const config = self.configuration_service orelse return;
        const service = config.interface();
        if (self.history) |view| view.setConfig(scm_history.Config.read(service));
        if (self.changes) |view| view.setConfig(scm_view.Config.read(service));
    }

    fn onProviderChanged(_: void, self: *SCMContribution) !void {
        self.applyProviderState();
    }

    fn onActiveRepositoryChanged(active: ?scm.ActiveRepository, self: *SCMContribution) !void {
        if (self.history) |view| {
            const provider = if (active) |entry| entry.repository.provider.history_provider else null;
            if (view.provider != provider) view.setProvider(provider);
        }
        self.applyProviderState();
    }

    fn applyProviderState(self: *SCMContribution) void {
        const service = self.service_api orelse return;
        const repositories = service.repositories();
        for (repositories) |repository| {
            const provider = repository.provider;
            if (provider.input_box_visible) |visible| repository.input.setVisible(visible);
            if (provider.input_box_placeholder) |placeholder| repository.input.setPlaceholder(placeholder);
        }
        const repository = if (self.view_service_api) |view_service| active: {
            break :active if (view_service.activeRepository()) |active| active.repository else null;
        } else null;
        if (self.changes) |view| {
            view.branch_action = if (repository) |entry| entry.provider.branch_action else null;
            view.fresh_repository = if (repository) |entry| entry.provider.fresh_repository else false;
            view.refresh();
        }
        if (self.view_descriptors) |descriptors| {
            var any_history = false;
            for (repositories) |entry| if (entry.provider.history_provider != null) {
                any_history = true;
                break;
            };
            descriptors.setViewAvailable("graph", any_history);
        }
        if (self.container) |container| container.updateTitleArea();
    }

    /// Configure the view before mounting its history provider (initial query
    /// uses the configured filter and graph options).
    pub fn attachHistoryProvider(self: *SCMContribution, provider: *const scm.ISCMProvider, theme: ?*const ThemeColors) void {
        const history = self.history orelse return;
        if (theme) |palette| history.setThemeColors(palette);
        if (provider.history_provider) |history_provider| history.setProvider(history_provider);
    }

    /// The attached providers are borrowed. Tear down their listeners and
    /// destroy all views and services before the extension releases them.
    pub fn detachProvider(self: *SCMContribution) void {
        const allocator = self.allocator;
        if (self.container) |container| self.sidebar.?.disposeViewPaneContainer(self.view_descriptors.?, container);
        if (self.view_model) |model| {
            model.deinit();
            allocator.destroy(model);
        }
        self.container = null;
        self.view_model = null;
        if (self.view_descriptors) |descriptors| {
            descriptors.setViewAvailable("changes", false);
            descriptors.setViewAvailable("graph", false);
        }
        self.detachConfiguration();
        if (self.active_repository_listener) |listener| listener.dispose();
        if (self.activity) |activity| activity.destroy();
        if (self.history) |view| {
            view.deinit();
            allocator.destroy(view);
        }
        if (self.quick_diff_controller) |controller| {
            controller.deinit();
            allocator.destroy(controller);
        }
        if (self.changes) |view| {
            view.deinit();
            allocator.destroy(view);
        }
        if (self.quick_diff_model_service) |models| models.setRepositoryResources(null) catch {};
        for (self.provider_bindings.items) |binding| binding.dispose(allocator);
        self.provider_bindings.deinit(allocator);
        if (self.resource_events) |events| {
            events.deinit();
            allocator.destroy(events);
        }
        if (self.storage) |storage| {
            storage.deinit();
            allocator.destroy(storage);
        }
        const service = self.service;
        const api = self.service_api;
        const view_service = self.view_service;
        const view_api = self.view_service_api;
        const quick_service = self.quick_diff_service;
        const quick_api = self.quick_diff_api;
        const models = self.quick_diff_model_service;
        const models_api = self.quick_diff_model_api;
        self.* = init(allocator);
        self.service = service;
        self.service_api = api;
        self.view_service = view_service;
        self.view_service_api = view_api;
        self.quick_diff_service = quick_service;
        self.quick_diff_api = quick_api;
        self.quick_diff_model_service = models;
        self.quick_diff_model_api = models_api;
    }

    pub fn deinit(self: *SCMContribution) void {
        self.detachProvider();
        if (self.view_service_api) |api| self.allocator.destroy(api);
        if (self.view_service) |service| service.destroy();
        self.view_service_api = null;
        self.view_service = null;
        if (self.quick_diff_model_api) |api| self.allocator.destroy(api);
        if (self.quick_diff_model_service) |models| {
            models.deinit();
            self.allocator.destroy(models);
        }
        if (self.quick_diff_api) |api| self.allocator.destroy(api);
        if (self.quick_diff_service) |service| {
            service.deinit();
            self.allocator.destroy(service);
        }
        self.quick_diff_model_api = null;
        self.quick_diff_model_service = null;
        self.quick_diff_service = null;
        self.quick_diff_api = null;
        if (self.service_api) |api| self.allocator.destroy(api);
        if (self.service) |service| {
            service.deinit();
            self.allocator.destroy(service);
        }
        self.service = null;
        self.service_api = null;
    }
};

pub const view_actions = scm_history.view_actions ++ scm_view.view_actions;

// "scm" is the native activity alias for the upstream VIEWLET_ID.
pub fn registerViewContainer(registry: *@import("../../../common/views.zig").ViewContainersRegistry) !void {
    _ = try registry.register(.{
        .id = "scm",
        .title = "Source Control",
        .glyph = '\u{e702}',
        .order = 2,
    }, .sidebar, .{});
}

pub fn registerViews(registry: *@import("../../../common/views.zig").ViewsRegistry) !void {
    // Repository-list view remains unported; native provider availability
    // replaces the upstream SCM context-key when expressions.
    try registry.registerViews(&.{
        .{ .id = "changes", .name = "Changes", .order = 1, .weight = 40, .available = false },
        .{ .id = "graph", .name = "Graph", .order = 2, .weight = 40, .available = false },
    }, "scm");
}

const Action2 = @import("../../../../platform/actions/common/actions.zig").Action2;
const Accessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const pane_composite = @import("../../../services/panecomposite/browser/panecomposite.zig");
const views_service = @import("../../../services/views/common/viewsService.zig");

pub const show_scm_action: Action2 = .{
    .command = .{ .id = "workbench.view.scm", .title = "View: Show Source Control", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = showSourceControl,
};

fn showSourceControl(_: *anyopaque, accessor: Accessor) !void {
    const service = try accessor.get(pane_composite.pane_composite_part_service_id);
    if (!try service.openPaneComposite("scm", .sidebar, true)) return;
    const views = try accessor.get(views_service.views_service_id);
    if (views.getViewWithId(scm_view.SCMViewPane)) |view| view.refresh();
}

pub const show_menu_action = @import("../../../browser/parts/sidebar/sidebarPart.zig").containerMenuAction("workbench.scm.action.showMenu", "Source Control More Actions", "scm");
