// Port of the SCM view contribution registrations in
// `src/vs/workbench/contrib/scm/browser/scm.contribution.ts`.
// The terminal uses explicit construction rather than SyncDescriptor and
// singleton decorators. The contribution owns the service and the Changes,
// Graph and quick-diff controllers, while the sidebar hosts its view panes.
// The native extension supplies ISCMProvider and QuickDiffProvider objects;
// multi-repository view and working-set controllers remain unported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const scm = @import("../common/scm.zig");
const SCMService = @import("../common/scmService.zig").SCMService;
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
    repository: ?*scm.ISCMRepository = null,
    storage: ?*Storage = null,
    quick_diff_service: ?*quick_diff.QuickDiffService = null,
    quick_diff_api: ?*quick_diff.IQuickDiffService = null,
    quick_diff_model_service: ?*quick_models.QuickDiffModelService = null,
    quick_diff_model_api: ?*quick_models.IQuickDiffModelService = null,
    registered_quick_providers: []quick_diff.IDisposable = &.{},
    additional_providers: std.ArrayList(AdditionalProvider) = .empty,
    resource_events: ?*@import("../../../../base/common/event.zig").Emitter(void) = null,
    primary_resources_listener: ?@import("../../../../base/common/event.zig").SignalSubscription = null,

    quick_diff_controller: ?*QuickDiffWorkbenchController = null,
    changes: ?*scm_view.SCMViewPane = null,
    history: ?*scm_history.SCMHistoryViewPane = null,
    activity: ?*SCMActiveRepositoryController = null,
    provider_event: ?*@import("../../../../base/common/event.zig").Emitter(void) = null,
    provider_listener: ?usize = null,
    configuration_service: ?*ConfigurationService = null,
    configuration_listener: ?usize = null,

    const AdditionalProvider = struct {
        repository: *scm.ISCMRepository,
        quick_registrations: []quick_diff.IDisposable,
        resource_listener: @import("../../../../base/common/event.zig").SignalSubscription,
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
        if (self.repository != null) return error.ProviderAlreadyExists;
        errdefer self.detachProvider();
        const api = try self.ensureService();
        self.repository = try api.registerSCMProvider(provider);
        self.activity = try SCMActiveRepositoryController.create(allocator, provider, options.activity_service, options.statusbar_service, options.configuration);

        const storage = try allocator.create(Storage);
        storage.* = Storage.init(allocator);
        self.storage = storage;
        _ = try self.ensureQuickDiffServices(options.window, options.text_model_service, null);
        const quick_service = self.quick_diff_service.?;
        const models = self.quick_diff_model_service.?;
        self.registered_quick_providers = try allocator.alloc(quick_diff.IDisposable, quick_providers.len);
        @memset(self.registered_quick_providers, quick_diff.IDisposable.none);
        for (quick_providers, self.registered_quick_providers) |quick, *registration| registration.* = try quick_service.addQuickDiffProvider(quick);
        const resource_events = try allocator.create(@import("../../../../base/common/event.zig").Emitter(void));
        resource_events.* = .init(allocator);
        self.resource_events = resource_events;
        self.primary_resources_listener = try provider.on_did_change_resources.listenDisposable(self, onRepositoryResourcesChanged);
        try models.setRepositoryResources(resource_events);

        const controller = try allocator.create(QuickDiffWorkbenchController);
        controller.* = QuickDiffWorkbenchController.init(allocator, quick_service.interface(), models);
        self.quick_diff_controller = controller;
        controller.view_factory = options.view_factory;
        controller.quick_input = options.quick_input;
        controller.menu_host = options.quick_diff_menu;
        try controller.start(options.editors, options.configuration);

        const view = try allocator.create(scm_view.SCMViewPane);
        view.* = scm_view.SCMViewPane.init(allocator, api, options.changes_host);
        self.changes = view;

        const history = try scm_history.SCMHistoryViewPane.init(allocator, options.history_host, storage);
        self.history = history;
        history.quick_input = options.quick_input;
        self.provider_event = provider.on_did_change orelse provider.on_did_change_resources;
        self.provider_listener = try self.provider_event.?.listen(self, onProviderChanged);
        try self.setViewConfiguration(options.configuration);
        self.applyProviderState();
    }

    /// Secondary repositories share the same SCM service, Changes tree and
    /// Quick Diff model collection. The repository and Quick Diff registrations
    /// are disposed before the extension releases their providers.
    pub fn registerAdditionalProvider(self: *SCMContribution, provider: *scm.ISCMProvider, quick_providers: []const *quick_diff.QuickDiffProvider) !void {
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
        const resource_listener = try provider.on_did_change_resources.listenDisposable(self, onAdditionalRepositoryResourcesChanged);
        errdefer resource_listener.dispose();
        try self.additional_providers.append(self.allocator, .{ .repository = repository, .quick_registrations = registrations, .resource_listener = resource_listener });
        self.applyProviderState();
    }

    fn onRepositoryResourcesChanged(_: void, self: *SCMContribution) !void {
        if (self.resource_events) |events| try events.fire({});
    }

    fn onAdditionalRepositoryResourcesChanged(_: void, self: *SCMContribution) !void {
        try onRepositoryResourcesChanged({}, self);
        if (self.changes) |view| view.refresh();
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

    fn applyProviderState(self: *SCMContribution) void {
        const service = self.service_api orelse return;
        const repositories = service.repositories();
        if (repositories.len == 0) return;
        const repository = repositories[0];
        const provider = repository.provider;
        if (provider.input_box_visible) |visible| repository.input.setVisible(visible);
        if (provider.input_box_placeholder) |placeholder| repository.input.setPlaceholder(placeholder);
        if (self.changes) |view| {
            view.branch_action = provider.branch_action;
            view.fresh_repository = provider.fresh_repository;
            view.refresh();
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
        if (self.provider_listener) |listener| self.provider_event.?.unlisten(listener);
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
        if (self.primary_resources_listener) |listener| listener.dispose();
        for (self.additional_providers.items) |additional| {
            additional.resource_listener.dispose();
            for (additional.quick_registrations) |registration| registration.dispose();
            allocator.free(additional.quick_registrations);
            additional.repository.dispose();
        }
        self.additional_providers.deinit(allocator);
        if (self.resource_events) |events| {
            events.deinit();
            allocator.destroy(events);
        }
        for (self.registered_quick_providers) |registration| registration.dispose();
        allocator.free(self.registered_quick_providers);
        if (self.repository) |repository| repository.dispose();
        if (self.storage) |storage| {
            storage.deinit();
            allocator.destroy(storage);
        }
        const service = self.service;
        const api = self.service_api;
        const quick_service = self.quick_diff_service;
        const quick_api = self.quick_diff_api;
        const models = self.quick_diff_model_service;
        const models_api = self.quick_diff_model_api;
        self.* = init(allocator);
        self.service = service;
        self.service_api = api;
        self.quick_diff_service = quick_service;
        self.quick_diff_api = quick_api;
        self.quick_diff_model_service = models;
        self.quick_diff_model_api = models_api;
    }

    pub fn deinit(self: *SCMContribution) void {
        self.detachProvider();
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
