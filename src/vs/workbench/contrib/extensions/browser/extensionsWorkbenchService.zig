// Port of `src/vs/workbench/contrib/extensions/browser/extensionsWorkbenchService.ts`.
// Owns the local and gallery inventories, enablement, installation operations
// and onChange delivery. The terminal uses a single local server and the
// effective user directory. Host-only changes can restart the local host;
// mounted declarative points still require restarting the window. Automatic
// checks and signed unattended installations are separate from Marketplace
// queries; additional profiles and dynamic static-point deltas remain unported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const scanner = @import("../../../../platform/extensionManagement/common/extensionsScannerService.zig");
const util = @import("../../../../platform/extensionManagement/common/extensionManagementUtil.zig");
const enablement_mod = @import("../../../services/extensionManagement/browser/extensionEnablementService.zig");
const model = @import("../common/extensions.zig");
const IExtension = model.IExtension;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const management = @import("../../../../platform/extensionManagement/node/extensionManagementService.zig");
const gallery = @import("../../../../platform/extensionManagement/common/extensionGalleryService.zig");
const dialogs = @import("../../../../platform/dialogs/common/dialogs.zig");
const quick = @import("../../../../platform/quickinput/common/quickInput.zig");
const EnablementState = model.EnablementState;
const storage = @import("../../../../platform/storage/common/storage.zig");
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const lifecycle = @import("../../../services/lifecycle/common/lifecycle.zig");
const time = @import("../../../../base/common/timeCompat.zig");
const extension_status = @import("../../../services/extensions/common/extensions.zig");
const RuntimeInventory = @import("../../../services/extensions/common/abstractExtensionService.zig").RuntimeInventory;

pub const Options = struct {
    system_location: ?[]const u8 = null,
    user_location: ?[]const u8 = null,
    enablement: *enablement_mod.ExtensionEnablementService,
    gallery_url: ?[]const u8 = null,
};

/// One immutable generation of the scanned inventory. `local` borrows the
/// manifest strings owned by `inventory`; the pair is replaced together.
const ModelState = struct {
    inventory: scanner.ScanResult,
    local: []IExtension,
    /// Descriptions whose enablement state is enabled, in merged order.
    enabled: std.array_list.Managed(*const scanner.ScannedExtension),
};

pub const GalleryKind = enum { search, popular, recommended, lookup };

const GalleryState = struct {
    arena: std.heap.ArenaAllocator,
    page: gallery.Page,
    rows: []IExtension,

    fn deinit(self: *GalleryState) void {
        self.arena.deinit();
        self.page.deinit();
    }
};

const UpdateRequest = struct { identifier: []const u8, prerelease: bool, executes_code: bool };
const UpdateState = struct {
    arena: std.heap.ArenaAllocator,
    rows: []IExtension = &.{},
    fn deinit(self: *UpdateState) void {
        self.arena.deinit();
    }
};
const UpdateJob = struct {
    service: *ExtensionsWorkbenchService,
    arena: std.heap.ArenaAllocator,
    requests: []UpdateRequest,
    url: []const u8,
    completion: dispatch.Task,
    future: std.Io.Future(anyerror!UpdateState),
    fn deinit(self: *UpdateJob) void {
        const allocator = self.service.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};
fn galleryExecutesCode(allocator: Allocator, io: std.Io, version: gallery.Version, local_executes_code: bool) ?bool {
    if (version.property("Microsoft.VisualStudio.Code.ExecutesCode")) |value| return std.mem.eql(u8, value, "true");
    if (local_executes_code) return null; // no new code consent check needed
    const url = version.asset("Microsoft.VisualStudio.Code.Manifest") orelse return null;
    const bytes = gallery.getAsset(allocator, io, url) catch return null;
    defer allocator.free(bytes);
    const manifest = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer manifest.deinit();
    if (manifest.value != .object) return null;
    return manifest.value.object.contains("main") or manifest.value.object.contains("browser");
}

fn queryInstalledUpdates(allocator: Allocator, io: std.Io, url: []const u8, requests: []const UpdateRequest) !UpdateState {
    const service: gallery.ExtensionGalleryService = .{ .allocator = allocator, .io = io, .service_url = url };
    var result: UpdateState = .{ .arena = .init(allocator) };
    errdefer result.deinit();
    const scratch = result.arena.allocator();
    var rows: std.ArrayList(IExtension) = .empty;
    var offset: usize = 0;
    // The gallery names filter is OR-ed within a filter. Batch so a large
    // installed inventory does not silently drop entries from the response.
    while (offset < requests.len) {
        const batch = requests[offset..@min(offset + 50, requests.len)];
        var criteria: [50]gallery.Criterion = undefined;
        for (batch, 0..) |request, index| criteria[index] = .{ .filterType = @backingInt(gallery.FilterType.extension_name), .value = request.identifier };
        var page = try service.query(.{ .criteria = criteria[0..batch.len], .page_size = batch.len, .all_versions = true });
        defer page.deinit();
        for (page.extensions) |entry| {
            const id = try util.getGalleryExtensionId(scratch, entry.publisher.publisherName, entry.extensionName);
            for (batch) |request| {
                if (!util.areSameExtensions(request.identifier, id)) continue;
                const version = entry.selectVersion(null, request.prerelease) orelse break;
                try rows.append(scratch, try (IExtension{
                    .identifier = id,
                    .name = entry.extensionName,
                    .display_name = entry.displayName orelse entry.extensionName,
                    .description = entry.shortDescription orelse "",
                    .version = version.version,
                    .publisher = entry.publisher.displayName orelse entry.publisher.publisherName,
                    .categories = entry.categories orelse &.{},
                    .location = "",
                    .is_builtin = false,
                    .state = .Installed,
                    .is_pre_release = version.isPreRelease(),
                    .install_count = entry.statistic("install"),
                    .rating = entry.statistic("averagerating"),
                    .rating_count = entry.statistic("ratingcount"),
                    .publisher_domain = entry.publisher.domain,
                    .publisher_verified = entry.publisher.domain != null and (entry.publisher.isDomainVerified orelse false),
                    .has_pre_release = entry.selectReleaseChannel(true) != null,
                    .manifest_url = version.asset("Microsoft.VisualStudio.Code.Manifest"),
                    .readme_url = version.asset("Microsoft.VisualStudio.Services.Content.Details"),
                    .changelog_url = version.asset("Microsoft.VisualStudio.Services.Content.Changelog"),
                    .vsix_url = version.asset("Microsoft.VisualStudio.Services.VSIXPackage"),
                    .target_platform = version.targetPlatform,
                    .uuid = entry.extensionId,
                    .last_updated = if (entry.lastUpdated orelse version.lastUpdated) |timestamp| gallery.parseGalleryTimestamp(timestamp) else null,
                    .release_date = if (entry.releaseDate) |timestamp| gallery.parseGalleryTimestamp(timestamp) else null,
                    .executes_code = galleryExecutesCode(allocator, io, version, request.executes_code),
                }).clone(scratch));
                break;
            }
        }
        offset += batch.len;
    }
    result.rows = rows.items;
    return result;
}
fn runUpdates(job: *UpdateJob) anyerror!UpdateState {
    defer job.completion.post();
    const io = job.service.window.?.io;
    return dispatch.workerCall(io, queryInstalledUpdates, .{ job.service.allocator, dispatch.backingIo(io), job.url, job.requests });
}

const Operation = enum { install, uninstall, install_vsix, update_metadata };
const ManagementJob = struct {
    service: *ExtensionsWorkbenchService,
    operation: Operation,
    arena: std.heap.ArenaAllocator,
    location: []const u8,
    identifier: []const u8,
    identifiers: []const []const u8,
    version: []const u8,
    url: []const u8,
    system_location: ?[]const u8,
    gallery_url: []const u8,
    prerelease: bool,
    pinned: bool,
    target_platform: ?[]const u8,
    uuid: ?[]const u8,
    verify_signature: bool,
    require_verified: bool,
    future: std.Io.Future(anyerror!void),
    completion: dispatch.Task,

    fn deinit(self: *ManagementJob) void {
        const allocator = self.service.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

fn runManagement(job: *ManagementJob) anyerror!void {
    defer job.completion.post();
    const io = job.service.window.?.io;
    switch (job.operation) {
        .install => try dispatch.workerCall(io, management.installFromGallery, .{ job.service.allocator, dispatch.backingIo(io), job.location, job.system_location, job.gallery_url, job.url, job.identifier, job.version, job.prerelease, job.pinned, job.target_platform, job.uuid, job.verify_signature, job.require_verified }),
        .install_vsix => try dispatch.workerCall(io, management.installVSIXFile, .{ job.service.allocator, dispatch.backingIo(io), job.location, job.system_location, job.gallery_url, job.url }),
        .update_metadata => try dispatch.workerCall(io, management.updatePinned, .{ job.service.allocator, dispatch.backingIo(io), job.location, job.identifier, job.pinned }),
        .uninstall => try dispatch.workerCall(io, management.uninstallMany, .{ job.service.allocator, dispatch.backingIo(io), job.location, job.identifiers }),
    }
}

const OpenJob = struct {
    service: *ExtensionsWorkbenchService,
    identifier: []u8,
    url: ?[]u8,
    completion: dispatch.Task,
    future: ?std.Io.Future(anyerror!gallery.Page) = null,
    fn deinit(self: *OpenJob) void {
        const allocator = self.service.allocator;
        allocator.free(self.identifier);
        if (self.url) |url| allocator.free(url);
        allocator.destroy(self);
    }
};
fn runOpen(job: *OpenJob) anyerror!gallery.Page {
    defer job.completion.post();
    const io = job.service.window.?.io;
    return dispatch.workerCall(io, queryVersions, .{ job.service.allocator, dispatch.backingIo(io), job.url.?, job.identifier });
}

const VersionMode = enum { picker, release, prerelease };
const VersionJob = struct {
    service: *ExtensionsWorkbenchService,
    input: quick.IQuickInputService,
    mode: VersionMode,
    identifier: []u8,
    url: []u8,
    completion: dispatch.Task,
    future: std.Io.Future(anyerror!gallery.Page),
};
fn queryVersions(allocator: Allocator, io: std.Io, url: []const u8, identifier: []const u8) !gallery.Page {
    return (gallery.ExtensionGalleryService{ .allocator = allocator, .io = io, .service_url = url }).getExtension(identifier);
}
fn runVersions(job: *VersionJob) anyerror!gallery.Page {
    defer job.completion.post();
    const io = job.service.window.?.io;
    return dispatch.workerCall(io, queryVersions, .{ job.service.allocator, dispatch.backingIo(io), job.url, job.identifier });
}
const VersionPicker = struct {
    owner: ?*ExtensionsWorkbenchService,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    identifier: []const u8,
    choices: []gallery.Version,
    uuid: ?[]const u8 = null,

    fn dispose(self: *VersionPicker) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn selected(context: *anyopaque, item: ?*const quick.Item) !void {
        const self: *VersionPicker = @ptrCast(@alignCast(context));
        defer self.dispose();
        const service = self.owner orelse return;
        service.version_picker = null;
        const choice = item orelse return;
        for (self.choices) |version| {
            if (!std.mem.eql(u8, choice.id, version.version)) continue;
            const url = version.asset("Microsoft.VisualStudio.Services.VSIXPackage") orelse return;
            try service.startManagementTarget(.install, self.identifier, version.version, url, version.isPreRelease(), true, version.targetPlatform, self.uuid, false);
            return;
        }
    }
};

const PendingDependencyChange = struct {
    owner: *ExtensionsWorkbenchService,
    arena: std.heap.ArenaAllocator,
    identifiers: []const []const u8,
    state: ?EnablementState,

    fn complete(context: *anyopaque, result: dialogs.IConfirmationResult) void {
        const self: *PendingDependencyChange = @ptrCast(@alignCast(context));
        self.owner.pending_dialog = null;
        if (!result.confirmed) return;
        if (self.state) |state| {
            _ = self.owner.applyDisablement(self.identifiers, state) catch |err| {
                self.owner.management_error = err;
                self.owner.on_change.fire({}) catch {};
                return;
            };
        } else self.owner.startManagementMany(.uninstall, self.identifiers[0], "", "", false, false, self.identifiers, null, null, false) catch |err| {
            self.owner.management_error = err;
            self.owner.on_change.fire({}) catch {};
        };
    }

    fn dispose(context: *anyopaque) void {
        const self: *PendingDependencyChange = @ptrCast(@alignCast(context));
        const allocator = self.owner.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

pub const ExtensionsWorkbenchService = struct {
    allocator: Allocator,
    io: std.Io,
    system_location: ?[]u8 = null,
    user_location: ?[]u8 = null,
    state: ModelState,
    feature_registry: @import("../../../services/extensionManagement/common/extensionFeatures.zig").ExtensionFeaturesRegistry,
    gallery_url: ?[]u8 = null,
    gallery_state: ?GalleryState = null,
    popular_state: ?GalleryState = null,
    recommended_state: ?GalleryState = null,
    lookup_state: ?GalleryState = null,
    open_job: ?*OpenJob = null,
    open_editor: ?struct { context: *anyopaque, run: *const fn (*anyopaque, []const u8) anyerror!void } = null,
    updates: ?UpdateState = null,
    update_job: ?*UpdateJob = null,
    update_timer: dispatch.Task = .{},
    auto_update_timer: dispatch.Task = .{},
    auto_update_index: usize = 0,
    update_configuration: ?configuration.IConfigurationService = null,
    update_storage: ?storage.IStorageService = null,
    update_storage_listener: ?@import("../../../../base/common/event.zig").SignalSubscription = null,
    configuration_listener: ?@import("../../../../base/common/event.zig").SignalSubscription = null,
    window: ?*dispatch.Queue = null,
    workspace: ?*@import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService = null,
    workspace_listener: ?@import("../../../../base/common/event.zig").SignalSubscription = null,
    management_job: ?*ManagementJob = null,
    management_error: ?anyerror = null,
    version_job: ?*VersionJob = null,
    version_picker: ?*VersionPicker = null,
    quick_input: ?quick.IQuickInputService = null,
    pane_service: ?@import("../../../services/panecomposite/browser/panecomposite.zig").IPaneCompositePartService = null,
    dialog_service: ?dialogs.IDialogService = null,
    context_menu: ?@import("../../../../platform/contextview/browser/contextMenuService.zig").IContextMenuService = null,
    pending_dialog: ?dialogs.IDialogHandle = null,
    runtime: ?RuntimeInventory = null,
    runtime_status: ?extension_status.IExtensionStatusService = null,
    runtime_status_listener: ?@import("../../../../base/common/event.zig").SignalSubscription = null,
    restart_host: ?struct { context: *anyopaque, restart: *const fn (*anyopaque) anyerror!void } = null,
    enablement: *enablement_mod.ExtensionEnablementService,
    on_change: Emitter(void),
    on_recommendations_change: Emitter(void),
    on_did_change_enabled_descriptions: Emitter(void),
    on_search_request: Emitter([]const u8),

    pub fn init(allocator: Allocator, io: std.Io, options: Options) !*ExtensionsWorkbenchService {
        const self = try allocator.create(ExtensionsWorkbenchService);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .state = .{
                .inventory = .{ .system = &.{}, .user = &.{}, .all = &.{} },
                .local = &.{},
                .enabled = std.array_list.Managed(*const scanner.ScannedExtension).init(allocator),
            },
            .enablement = options.enablement,
            .feature_registry = .init(allocator),
            .on_change = Emitter(void).init(allocator),
            .on_recommendations_change = Emitter(void).init(allocator),
            .on_did_change_enabled_descriptions = Emitter(void).init(allocator),
            .on_search_request = Emitter([]const u8).init(allocator),
        };
        errdefer self.deinitContents();
        if (options.gallery_url) |url| self.gallery_url = try allocator.dupe(u8, url);
        if (options.system_location) |location| self.system_location = try allocator.dupe(u8, location);
        if (options.user_location) |location| self.user_location = try allocator.dupe(u8, location);
        const state = try self.scan();
        // The initial empty state owns nothing.
        self.freeState(self.replaceState(state));
        return self;
    }

    pub fn deinit(self: *ExtensionsWorkbenchService) void {
        self.deinitContents();
        self.allocator.destroy(self);
    }

    fn deinitContents(self: *ExtensionsWorkbenchService) void {
        self.detachWindow();
        self.freeState(self.state);
        self.feature_registry.deinit();
        if (self.runtime) |*runtime| runtime.deinit();
        if (self.gallery_state) |*state| state.deinit();
        if (self.popular_state) |*state| state.deinit();
        if (self.recommended_state) |*state| state.deinit();
        if (self.lookup_state) |*state| state.deinit();
        if (self.updates) |*updates| updates.deinit();
        if (self.gallery_url) |url| self.allocator.free(url);
        self.on_change.deinit();
        self.on_recommendations_change.deinit();
        self.on_did_change_enabled_descriptions.deinit();
        self.on_search_request.deinit();
        if (self.system_location) |location| self.allocator.free(location);
        if (self.user_location) |location| self.allocator.free(location);
        self.system_location = null;
        self.user_location = null;
    }

    fn replaceState(self: *ExtensionsWorkbenchService, next: ModelState) ModelState {
        const previous = self.state;
        self.state = next;
        return previous;
    }

    fn freeState(self: *ExtensionsWorkbenchService, state: ModelState) void {
        var inventory = state.inventory;
        inventory.deinit(self.allocator);
        self.allocator.free(state.local);
        var enabled = state.enabled;
        enabled.deinit();
    }

    fn scan(self: *ExtensionsWorkbenchService) !ModelState {
        const inventory = try scanner.scanAllExtensions(self.allocator, self.io, self.system_location, self.user_location);
        errdefer {
            var owned = inventory;
            owned.deinit(self.allocator);
        }
        const local = try self.allocator.alloc(IExtension, inventory.all.len);
        errdefer self.allocator.free(local);
        for (inventory.all, 0..) |extension, index| {
            const manifest = extension.manifest.value;
            const metadata = if (manifest == .object) manifest.object.get("__metadata") orelse .null else .null;
            const timestamp = if (metadata == .object) metadata.object.get("installedTimestamp") orelse .null else .null;
            const updated = if (metadata == .object) metadata.object.get("updated") orelse .null else .null;
            const pinned = if (metadata == .object) metadata.object.get("pinned") orelse .null else .null;
            const prerelease = if (metadata == .object) metadata.object.get("preRelease") orelse .null else .null;
            const uuid = if (metadata == .object) metadata.object.get("id") orelse .null else .null;
            const source = if (metadata == .object) metadata.object.get("source") orelse .null else .null;
            local[index] = .{
                .identifier = extension.identifier,
                .name = extension.name,
                .display_name = extension.display_name,
                .description = extension.description,
                .version = extension.version,
                .publisher = extension.publisher,
                .categories = extension.categories,
                .location = extension.location,
                .is_builtin = extension.isBuiltin(),
                .enablement_state = self.enablement.getEnablementState(extension.identifier),
                .installed_timestamp = if (timestamp == .integer) timestamp.integer else null,
                .updated = updated == .bool and updated.bool,
                .pinned = pinned == .bool and pinned.bool,
                .is_pre_release = prerelease == .bool and prerelease.bool,
                .uuid = if (uuid == .string) uuid.string else null,
                .source = if (source == .string) source.string else if (!extension.isBuiltin()) "local" else null,
                .executes_code = manifest == .object and (manifest.object.contains("main") or manifest.object.contains("browser")),
            };
        }

        var enabled: std.array_list.Managed(*const scanner.ScannedExtension) = .init(self.allocator);
        errdefer enabled.deinit();
        try self.computeEnablement(inventory, local, &enabled);
        return .{ .inventory = inventory, .local = local, .enabled = enabled };
    }

    fn dependencies(extension: *const scanner.ScannedExtension, key: []const u8) []const std.json.Value {
        const value = extension.manifest.value;
        const entries = if (value == .object) value.object.get(key) orelse .null else .null;
        return if (entries == .array) entries.array.items else &.{};
    }

    fn computeEnablement(self: *ExtensionsWorkbenchService, inventory: scanner.ScanResult, local: []IExtension, enabled: *std.array_list.Managed(*const scanner.ScannedExtension)) !void {
        try enabled.ensureTotalCapacity(inventory.all.len);
        for (local) |*extension| extension.enablement_state = self.enablement.getEnablementState(extension.identifier);
        // Start from user enablement and propagate disabled installed dependencies
        // to a fixed point. Cycles with no disabled member remain enabled.
        var changed = true;
        while (changed) {
            changed = false;
            for (inventory.all, local) |extension, *entry| {
                if (!entry.isEnabled()) continue;
                for (dependencies(extension, "extensionDependencies")) |dependency| {
                    if (dependency != .string) continue;
                    for (local) |candidate| if (util.areSameExtensions(candidate.identifier, dependency.string) and !candidate.isEnabled()) {
                        entry.enablement_state = .DisabledByExtensionDependency;
                        changed = true;
                        break;
                    };
                    if (!entry.isEnabled()) break;
                }
            }
        }
        enabled.clearRetainingCapacity();
        for (inventory.all, local) |extension, entry| if (entry.isEnabled()) enabled.appendAssumeCapacity(extension);
    }

    fn refreshEnablement(self: *ExtensionsWorkbenchService) !void {
        try self.computeEnablement(self.state.inventory, self.state.local, &self.state.enabled);
        try self.on_did_change_enabled_descriptions.fire({});
        self.updateGalleryLocalState();
        try self.on_change.fire({});
    }

    /// Called by the local host owner only after accepting the new inventory.
    pub fn setRuntimeStatusService(self: *ExtensionsWorkbenchService, service: ?extension_status.IExtensionStatusService) !void {
        if (self.runtime_status_listener) |listener| listener.dispose();
        self.runtime_status_listener = null;
        self.runtime_status = service;
        if (service) |status| self.runtime_status_listener = try status.on_did_change_extensions_status.listenSignal(self, runtimeStatusChanged);
        try self.on_change.fire({});
    }

    fn runtimeStatusChanged(self: *ExtensionsWorkbenchService) !void {
        try self.on_change.fire({});
    }

    pub fn getRuntimeStatus(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?extension_status.IExtensionsStatus {
        return if (self.runtime_status) |status| status.getStatus(identifier) else null;
    }

    pub fn recordRuntime(self: *ExtensionsWorkbenchService) !void {
        return self.acceptRuntime(try RuntimeInventory.init(self.allocator, self.enabledDescriptions()));
    }

    /// Takes ownership of precisely the registry generation acknowledged by
    /// the host, even if another inventory operation completed in the meantime.
    pub fn acceptRuntime(self: *ExtensionsWorkbenchService, next: RuntimeInventory) !void {
        if (self.runtime) |*previous| previous.deinit();
        self.runtime = next;
        try self.on_change.fire({});
    }

    pub fn runtimeState(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?RuntimeInventory.Action {
        const runtime = self.runtime orelse return null;
        const action = runtime.getRuntimeState(identifier, self.enabledDescriptions()) orelse return null;
        if (action == .RestartExtensions and runtime.requiresReload(self.enabledDescriptions())) return .ReloadWindow;
        return action;
    }

    pub fn restartExtensions(self: *ExtensionsWorkbenchService) !void {
        const runtime = self.runtime orelse return error.ExtensionHostUnavailable;
        if (runtime.requiresReload(self.enabledDescriptions())) return error.ReloadWindowRequired;
        const host = self.restart_host orelse return error.ExtensionHostUnavailable;
        try host.restart(host.context);
        try self.recordRuntime();
    }

    pub fn queryLocal(self: *const ExtensionsWorkbenchService) []const IExtension {
        return self.state.local;
    }

    pub fn localManifest(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?std.json.Value {
        for (self.state.inventory.all) |extension| {
            if (util.areSameExtensions(extension.identifier, identifier)) return extension.manifest.value;
        }
        return null;
    }

    pub fn findLocal(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?*const IExtension {
        for (self.state.local) |*extension| {
            if (util.areSameExtensions(extension.identifier, identifier)) return extension;
        }
        return null;
    }

    pub fn find(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?*const IExtension {
        if (self.findLocal(identifier)) |extension| return extension;
        return self.galleryInfo(identifier);
    }

    pub fn attachWindow(self: *ExtensionsWorkbenchService, window: *dispatch.Queue) void {
        if (self.window == window) return;
        if (self.window != null) self.detachWindow();
        self.window = window;
        self.update_timer = .{ .queue = window, .context = self, .run = checkUpdatesTask };
        self.auto_update_timer = .{ .queue = window, .context = self, .run = autoUpdateTask };
    }

    /// Start the upstream automatic update check after Eventually. The
    /// timer and worker are owned by this service and disposed with the window.
    pub fn attachUpdateChecks(self: *ExtensionsWorkbenchService, config: configuration.IConfigurationService, phases: lifecycle.ILifecycleService, state: storage.IStorageService) !void {
        if (self.update_configuration != null) return;
        self.update_configuration = config;
        self.update_storage = state;
        if (state.on_did_change_value) |event| self.update_storage_listener = try event.listenDisposable(self, updateStorageChanged);
        if (config.on_did_change_configuration) |event| self.configuration_listener = try event.listenDisposable(self, updateConfigurationChanged);
        try phases.when(.Eventually, .{ .context = self, .run = startUpdateChecks });
    }

    fn startUpdateChecks(context: *anyopaque) !void {
        const self: *ExtensionsWorkbenchService = @ptrCast(@alignCast(context));
        self.scheduleUpdateCheck(0);
    }

    fn updateConfigurationChanged(change: configuration.Change, self: *ExtensionsWorkbenchService) !void {
        if (configuration.affectsConfiguration(change, "extensions.showRecommendationsOnlyOnDemand")) try self.on_change.fire({});
        if (configuration.affectsConfiguration(change, "extensions.autoUpdate") or configuration.affectsConfiguration(change, "extensions.autoUpdateDelay")) {
            self.auto_update_index = 0;
            self.scheduleAutoUpdate();
            try self.on_change.fire({});
        }
        if (!configuration.affectsConfiguration(change, "extensions.autoCheckUpdates")) return;
        if (self.update_configuration.?.getBool("extensions.autoCheckUpdates", true)) self.scheduleUpdateCheck(0) else {
            self.update_timer.schedule(null);
            self.cancelUpdateCheck();
        }
    }

    fn scheduleUpdateCheck(self: *ExtensionsWorkbenchService, delay: i64) void {
        const window = self.window orelse return;
        const config = self.update_configuration orelse return;
        if (!config.getBool("extensions.autoCheckUpdates", true) or self.gallery_url == null) return;
        self.update_timer.schedule(time.milliTimestamp(window.workerIo()) + delay);
    }

    fn checkUpdatesTask(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ExtensionsWorkbenchService = @ptrCast(@alignCast(context));
        self.checkForUpdates() catch {};
        self.scheduleUpdateCheck(12 * 60 * 60 * 1000);
        return false;
    }

    pub fn checkForUpdates(self: *ExtensionsWorkbenchService) !void {
        const window = self.window orelse return error.ExtensionManagementUnavailable;
        const url = self.gallery_url orelse return error.GalleryUnavailable;
        self.cancelUpdateCheck();
        const job = try self.allocator.create(UpdateJob);
        errdefer self.allocator.destroy(job);
        job.* = .{ .service = self, .arena = .init(self.allocator), .requests = &.{}, .url = "", .completion = .{ .queue = window, .context = self, .run = applyUpdates, .progress = true }, .future = undefined };
        errdefer job.arena.deinit();
        const allocator = job.arena.allocator();
        job.url = try allocator.dupe(u8, url);
        var requests: std.ArrayList(UpdateRequest) = .empty;
        for (self.queryLocal()) |extension| {
            if (extension.is_builtin) continue;
            try requests.append(allocator, .{ .identifier = try allocator.dupe(u8, extension.identifier), .prerelease = extension.is_pre_release, .executes_code = extension.executes_code orelse false });
        }
        job.requests = requests.items;
        self.update_job = job;
        job.future = window.io.async(runUpdates, .{job});
    }

    fn cancelUpdateCheck(self: *ExtensionsWorkbenchService) void {
        const job = self.update_job orelse return;
        self.update_job = null;
        if (job.future.cancel(self.window.?.io)) |result| {
            var owned = result;
            owned.deinit();
        } else |_| {}
        job.completion.schedule(null);
        job.deinit();
    }

    fn applyUpdates(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ExtensionsWorkbenchService = @ptrCast(@alignCast(context));
        const job = self.update_job orelse return false;
        self.update_job = null;
        defer job.deinit();
        const next = job.future.await(self.window.?.io) catch return false;
        var previous = self.updates;
        self.updates = next;
        self.auto_update_index = 0;
        self.scheduleAutoUpdate();
        defer if (previous) |*old| old.deinit();
        self.updateGalleryLocalState();
        self.on_change.fire({}) catch {};
        return true;
    }

    fn autoUpdateEnabled(self: *const ExtensionsWorkbenchService) bool {
        const config = self.update_configuration orelse return false;
        const setting = config.getValue("extensions.autoUpdate") orelse return true;
        return switch (setting.*) {
            .string => |value| !std.mem.eql(u8, value, "off") and !std.mem.eql(u8, value, "onlySelectedExtensions"),
            .bool => |value| value,
            else => true,
        };
    }

    const enabled_auto_update_key = "extensions.autoUpdate";
    const disabled_auto_update_key = "extensions.donotAutoUpdate";

    fn updateStorageChanged(change: storage.IStorageValueChangeEvent, self: *ExtensionsWorkbenchService) !void {
        if (change.scope != .application or (!std.mem.eql(u8, change.key, enabled_auto_update_key) and !std.mem.eql(u8, change.key, disabled_auto_update_key))) return;
        self.auto_update_index = 0;
        self.scheduleAutoUpdate();
        try self.on_change.fire({});
    }

    fn autoUpdateEntries(self: *const ExtensionsWorkbenchService, arena: Allocator, key: []const u8) []const std.json.Value {
        const state = self.update_storage orelse return &.{};
        const raw = state.get(key, .application, null) orelse return &.{};
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return &.{};
        return if (value == .array) value.array.items else &.{};
    }

    pub fn isAutoUpdateEnabledFor(self: *const ExtensionsWorkbenchService, extension: IExtension) bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const on = self.autoUpdateEnabled();
        const entries = self.autoUpdateEntries(arena.allocator(), if (on) disabled_auto_update_key else enabled_auto_update_key);
        return autoUpdatePolicy(on, entries, extension);
    }

    pub fn canToggleAutoUpdate(self: *const ExtensionsWorkbenchService, extension: IExtension) bool {
        return self.update_storage != null and !extension.is_builtin and (!self.autoUpdateEnabled() or extension.isEnabled());
    }

    pub fn updateAutoUpdateEnablementFor(self: *ExtensionsWorkbenchService, extension: IExtension, enable: bool) !void {
        if (!self.canToggleAutoUpdate(extension)) return error.AutoUpdateUnavailable;
        const state = self.update_storage orelse return error.AutoUpdateUnavailable;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const id = try std.ascii.allocLowerString(allocator, extension.identifier);
        const negated = try std.fmt.allocPrint(allocator, "-{s}", .{id});
        const on = self.autoUpdateEnabled();
        const key = if (on) disabled_auto_update_key else enabled_auto_update_key;
        const entries = self.autoUpdateEntries(allocator, key);
        var next: std.ArrayList([]const u8) = .empty;
        for (entries) |entry| {
            if (entry != .string) continue;
            if (std.ascii.eqlIgnoreCase(entry.string, id) or std.ascii.eqlIgnoreCase(entry.string, negated)) continue;
            try next.append(allocator, entry.string);
        }
        if (on) {
            if (!enable) try next.append(allocator, id);
            if (enable and extension.pinned) try self.startManagement(.update_metadata, id, "", "", false, false);
        } else {
            const publisher_enabled = hasAutoUpdateEntry(entries, extension.publisherIdentifier());
            if (enable and !publisher_enabled) try next.append(allocator, id);
            if (!enable and publisher_enabled) try next.append(allocator, negated);
        }
        const raw = try std.json.Stringify.valueAlloc(allocator, next.items, .{});
        try state.store(key, .{ .string = raw }, .application, .user);
    }

    pub fn canTogglePublisherAutoUpdate(self: *const ExtensionsWorkbenchService) bool {
        return self.update_configuration != null and self.update_storage != null and !self.autoUpdateEnabled();
    }

    pub fn isPublisherAutoUpdateEnabled(self: *const ExtensionsWorkbenchService, publisher: []const u8) bool {
        if (self.autoUpdateEnabled()) return true;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        return hasAutoUpdateEntry(self.autoUpdateEntries(arena.allocator(), enabled_auto_update_key), publisher);
    }

    pub fn updatePublisherAutoUpdate(self: *ExtensionsWorkbenchService, publisher: []const u8, enable: bool) !void {
        if (!self.canTogglePublisherAutoUpdate()) return error.AutoUpdateUnavailable;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const entries = self.autoUpdateEntries(allocator, enabled_auto_update_key);
        var next: std.ArrayList([]const u8) = .empty;
        for (entries) |entry| {
            if (entry != .string or std.ascii.eqlIgnoreCase(entry.string, publisher)) continue;
            try next.append(allocator, entry.string);
        }
        if (enable) try next.append(allocator, try std.ascii.allocLowerString(allocator, publisher));
        const raw = try std.json.Stringify.valueAlloc(allocator, next.items, .{});
        try self.update_storage.?.store(enabled_auto_update_key, .{ .string = raw }, .application, .user);
    }

    fn scheduleAutoUpdate(self: *ExtensionsWorkbenchService) void {
        const window = self.window orelse return;
        if (self.update_configuration == null or self.updates == null or self.gallery_url == null or !@import("../../../../platform/extensionManagement/node/extensionSignatureVerificationService.zig").supportsGallery(self.gallery_url.?)) {
            self.auto_update_timer.schedule(null);
            return;
        }
        self.auto_update_timer.schedule(time.milliTimestamp(window.workerIo()) + 1000);
    }

    fn autoUpdateDelayHours(self: *const ExtensionsWorkbenchService) f64 {
        const config = self.update_configuration orelse return 12;
        const value = config.getValue("extensions.autoUpdateDelay") orelse return 12;
        const hours: f64 = switch (value.*) {
            .integer => |number| @floatFromInt(number),
            .float => |number| number,
            else => 12,
        };
        return if (std.math.isFinite(hours)) @max(0, hours) else 12;
    }

    fn autoUpdateTask(context: *anyopaque, now: i64, _: bool) bool {
        const self: *ExtensionsWorkbenchService = @ptrCast(@alignCast(context));
        if (self.update_configuration == null or self.management_job != null) return false;
        const updates = self.updates orelse return false;
        // Process each candidate once per gallery check. An unavailable or
        // unsigned version must not produce an immediate retry loop.
        while (self.auto_update_index < updates.rows.len) {
            const remote = updates.rows[self.auto_update_index];
            self.auto_update_index += 1;
            const local = self.findLocal(remote.identifier) orelse continue;
            if (!self.isAutoUpdateEnabledFor(local.*) or !isEligibleUpdate(local.*, remote, now, self.autoUpdateDelayHours())) continue;
            const url = remote.vsix_url orelse continue;
            self.startManagementTarget(.install, remote.identifier, remote.version, url, remote.is_pre_release, false, remote.target_platform, remote.uuid, true) catch continue;
            return true;
        }
        return false;
    }

    pub fn attachWorkspace(self: *ExtensionsWorkbenchService, workspace: *@import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService) !void {
        if (self.workspace == workspace) return;
        if (self.workspace_listener) |listener| listener.dispose();
        self.workspace_listener = null;
        self.workspace = workspace;
        self.workspace_listener = try workspace.on_did_change_workspace_folders.listenSignal(self, workspaceChanged);
        try self.workspaceChanged();
    }

    fn workspaceChanged(self: *ExtensionsWorkbenchService) !void {
        const workspace = self.workspace orelse return;
        if (try self.enablement.setWorkspace(workspace.getWorkspace())) try self.refreshEnablement();
        try self.on_recommendations_change.fire({});
    }

    pub fn detachWindow(self: *ExtensionsWorkbenchService) void {
        if (self.runtime_status_listener) |listener| listener.dispose();
        self.runtime_status_listener = null;
        self.runtime_status = null;
        self.cancelOpen();
        self.open_editor = null;
        self.cancelVersions();
        self.update_timer.schedule(null);
        self.update_timer = .{};
        self.auto_update_timer.schedule(null);
        self.auto_update_timer = .{};
        self.cancelUpdateCheck();
        if (self.configuration_listener) |listener| listener.dispose();
        self.configuration_listener = null;
        self.update_configuration = null;
        if (self.update_storage_listener) |listener| listener.dispose();
        self.update_storage_listener = null;
        self.update_storage = null;
        if (self.version_picker) |picker| picker.owner = null;
        self.version_picker = null;
        self.quick_input = null;
        self.pane_service = null;
        if (self.pending_dialog) |handle| {
            self.pending_dialog = null;
            handle.cancel();
        }
        self.dialog_service = null;
        self.context_menu = null;
        if (self.management_job) |job| {
            self.management_job = null;
            job.future.cancel(self.window.?.io) catch {};
            job.completion.schedule(null);
            job.deinit();
        }
        if (self.workspace_listener) |listener| listener.dispose();
        self.workspace_listener = null;
        self.window = null;
        self.workspace = null;
    }

    /// Resolve an installed or gallery identifier before opening a typed
    /// extension editor. Defer even a cached result so following a link from
    /// a preview cannot destroy that preview during its mouse handler.
    pub fn open(self: *ExtensionsWorkbenchService, identifier: []const u8) !void {
        const window = self.window orelse return error.ExtensionViewUnavailable;
        if (self.open_editor == null) return error.ExtensionViewUnavailable;
        self.cancelOpen();
        const owned_id = try self.allocator.dupe(u8, identifier);
        errdefer self.allocator.free(owned_id);
        const url = if (self.find(identifier) == null) try self.allocator.dupe(u8, self.gallery_url orelse return error.GalleryUnavailable) else null;
        errdefer if (url) |value| self.allocator.free(value);
        const job = try self.allocator.create(OpenJob);
        job.* = .{ .service = self, .identifier = owned_id, .url = url, .completion = .{ .queue = window, .context = self, .run = applyOpen, .progress = true } };
        self.open_job = job;
        if (url != null) job.future = window.io.async(runOpen, .{job}) else job.completion.post();
    }

    fn cancelOpen(self: *ExtensionsWorkbenchService) void {
        const job = self.open_job orelse return;
        self.open_job = null;
        if (job.future) |*future| {
            if (future.cancel(self.window.?.io)) |page| {
                var owned = page;
                owned.deinit();
            } else |_| {}
        }
        job.completion.schedule(null);
        job.deinit();
    }

    fn applyOpen(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ExtensionsWorkbenchService = @ptrCast(@alignCast(context));
        const job = self.open_job orelse return false;
        self.open_job = null;
        defer job.deinit();
        if (job.future) |*future| {
            const page = future.await(self.window.?.io) catch |err| {
                self.management_error = err;
                self.on_change.fire({}) catch {};
                return true;
            };
            self.setGalleryPage(page, false, .lookup) catch |err| {
                self.management_error = err;
                self.on_change.fire({}) catch {};
                return true;
            };
        }
        if (self.find(job.identifier) == null) {
            self.management_error = error.ExtensionNotFound;
            self.on_change.fire({}) catch {};
            return true;
        }
        if (self.open_editor) |editor| editor.run(editor.context, job.identifier) catch |err| {
            self.management_error = err;
            self.on_change.fire({}) catch {};
        };
        return true;
    }

    pub fn openSearch(self: *ExtensionsWorkbenchService, query: []const u8) !void {
        const panes = self.pane_service orelse return error.ExtensionViewUnavailable;
        _ = try panes.openPaneComposite(model.VIEW_ID, .sidebar, true);
        try self.on_search_request.fire(query);
    }

    pub fn galleryInfo(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?*const IExtension {
        for ([_]GalleryKind{ .search, .popular, .recommended, .lookup }) |kind| {
            for (self.galleryExtensionsFor(kind)) |*extension| if (util.areSameExtensions(extension.identifier, identifier)) return extension;
        }
        if (self.updates) |updates| for (updates.rows) |*extension| if (util.areSameExtensions(extension.identifier, identifier)) return extension;
        return null;
    }

    pub fn availableUpdate(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?*const IExtension {
        const local = self.findLocal(identifier) orelse return null;
        if (local.is_builtin) return null;
        const current = std.SemanticVersion.parse(local.version) catch return null;
        var best: ?*const IExtension = null;
        var best_version = current;
        const sources = [_][]const IExtension{ self.galleryExtensions(), self.galleryExtensionsFor(.popular), self.galleryExtensionsFor(.recommended), self.galleryExtensionsFor(.lookup), if (self.updates) |updates| updates.rows else &.{} };
        for (sources) |rows| for (rows) |*remote| {
            if (!util.areSameExtensions(remote.identifier, identifier) or remote.vsix_url == null) continue;
            if (remote.is_pre_release and !local.is_pre_release) continue;
            const candidate = std.SemanticVersion.parse(remote.version) catch continue;
            if (candidate.order(best_version) != .gt) continue;
            best = remote;
            best_version = candidate;
        };
        return best;
    }

    pub fn showVersions(self: *ExtensionsWorkbenchService, identifier: []const u8) !void {
        return self.queryVersionAction(identifier, .picker);
    }

    pub fn switchReleaseChannel(self: *ExtensionsWorkbenchService, identifier: []const u8, prerelease: bool) !void {
        return self.queryVersionAction(identifier, if (prerelease) .prerelease else .release);
    }

    fn queryVersionAction(self: *ExtensionsWorkbenchService, identifier: []const u8, mode: VersionMode) !void {
        const window = self.window orelse return error.ExtensionManagementUnavailable;
        const input = self.quick_input orelse return error.QuickInputUnavailable;
        const url = self.gallery_url orelse return error.GalleryUnavailable;
        self.cancelVersions();
        const owned_id = try self.allocator.dupe(u8, identifier);
        errdefer self.allocator.free(owned_id);
        const owned_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned_url);
        const job = try self.allocator.create(VersionJob);
        job.* = .{ .service = self, .input = input, .mode = mode, .identifier = owned_id, .url = owned_url, .completion = .{ .queue = window, .context = self, .run = applyVersions, .progress = true }, .future = undefined };
        self.version_job = job;
        job.future = window.io.async(runVersions, .{job});
    }

    fn disposeVersionJob(self: *ExtensionsWorkbenchService, job: *VersionJob) void {
        self.allocator.free(job.identifier);
        self.allocator.free(job.url);
        self.allocator.destroy(job);
    }

    fn cancelVersions(self: *ExtensionsWorkbenchService) void {
        const job = self.version_job orelse return;
        self.version_job = null;
        if (job.future.cancel(self.window.?.io)) |result| {
            var page = result;
            page.deinit();
        } else |_| {}
        job.completion.schedule(null);
        self.disposeVersionJob(job);
    }

    fn applyVersions(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ExtensionsWorkbenchService = @ptrCast(@alignCast(context));
        const job = self.version_job orelse return false;
        self.version_job = null;
        defer self.disposeVersionJob(job);
        var page = job.future.await(self.window.?.io) catch |err| {
            self.management_error = err;
            self.on_change.fire({}) catch {};
            return true;
        };
        defer page.deinit();
        self.completeVersionAction(job, page) catch |err| {
            self.management_error = err;
            self.on_change.fire({}) catch {};
        };
        return true;
    }

    fn completeVersionAction(self: *ExtensionsWorkbenchService, job: *VersionJob, page: gallery.Page) !void {
        if (job.mode == .picker) return self.presentVersions(job, page);
        for (page.extensions) |entry| {
            const id = try util.getGalleryExtensionId(self.allocator, entry.publisher.publisherName, entry.extensionName);
            defer self.allocator.free(id);
            if (!util.areSameExtensions(id, job.identifier)) continue;
            const version = entry.selectReleaseChannel(job.mode == .prerelease) orelse return error.CompatibleVersionNotFound;
            return self.startManagementTarget(.install, job.identifier, version.version, version.asset("Microsoft.VisualStudio.Services.VSIXPackage").?, version.isPreRelease(), false, version.targetPlatform, entry.extensionId, false);
        }
        return error.CompatibleVersionNotFound;
    }

    fn presentVersions(self: *ExtensionsWorkbenchService, job: *VersionJob, page: gallery.Page) !void {
        const picker = try self.allocator.create(VersionPicker);
        picker.* = .{ .owner = self, .allocator = self.allocator, .arena = .init(self.allocator), .identifier = "", .choices = &.{} };
        var adopted = false;
        defer if (!adopted) picker.dispose();
        const allocator = picker.arena.allocator();
        picker.identifier = try allocator.dupe(u8, job.identifier);
        var choices: std.ArrayList(gallery.Version) = .empty;
        var items: std.ArrayList(quick.QuickPickItem) = .empty;
        for (page.extensions) |entry| {
            const id = try util.getGalleryExtensionId(allocator, entry.publisher.publisherName, entry.extensionName);
            if (!util.areSameExtensions(id, job.identifier)) continue;
            picker.uuid = if (entry.extensionId) |uuid| try allocator.dupe(u8, uuid) else null;
            for (entry.versions) |version| {
                if (!version.isCompatible()) continue;
                const url = version.asset("Microsoft.VisualStudio.Services.VSIXPackage") orelse continue;
                for (choices.items) |existing| {
                    if (std.mem.eql(u8, version.version, existing.version)) break;
                } else {
                    const owned_version = try allocator.dupe(u8, version.version);
                    const owned_url = try allocator.dupe(u8, url);
                    const assets = try allocator.alloc(gallery.Asset, 1);
                    assets[0] = .{ .assetType = "Microsoft.VisualStudio.Services.VSIXPackage", .source = owned_url };
                    const properties: ?[]const gallery.Property = if (version.isPreRelease()) &[_]gallery.Property{.{ .key = "Microsoft.VisualStudio.Code.PreRelease", .value = "true" }} else null;
                    const target = if (version.targetPlatform) |platform| try allocator.dupe(u8, platform) else null;
                    try choices.append(allocator, .{ .version = owned_version, .files = assets, .properties = properties, .targetPlatform = target });
                    try items.append(allocator, .{ .item = .{ .id = owned_version, .label = owned_version, .description = if (version.isPreRelease()) "Pre-Release" else "Release" } });
                }
            }
        }
        if (items.items.len == 0) return error.CompatibleVersionNotFound;
        picker.choices = choices.items;
        // The picker bridge copies the item records but borrows their text
        // until accept/dismiss, so the session owns the arena.
        if (self.version_picker) |previous| previous.owner = null;
        self.version_picker = picker;
        errdefer self.version_picker = null;
        try job.input.pick(items.items, .{ .placeholder = "Select extension version", .active_id = if (self.findLocal(job.identifier)) |local| local.version else null }, VersionPicker.selected, picker);
        adopted = true;
    }

    pub fn operationState(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?model.ExtensionState {
        const job = self.management_job orelse return null;
        if (!util.areSameExtensions(job.identifier, identifier) and !containsIdentifier(job.identifiers, identifier)) return null;
        return switch (job.operation) {
            .install, .install_vsix => .Installing,
            .uninstall => .Uninstalling,
            .update_metadata => null,
        };
    }

    pub fn installFromVSIX(self: *ExtensionsWorkbenchService) !void {
        const input = self.quick_input orelse return error.QuickInputUnavailable;
        try input.input("Path to extension VSIX package", selectVSIX, self);
    }

    fn selectVSIX(context: *anyopaque, path: ?[]const u8) !void {
        const self: *ExtensionsWorkbenchService = @ptrCast(@alignCast(context));
        const selected = path orelse return;
        if (selected.len == 0) return;
        if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(selected), ".vsix")) return error.InvalidVSIXPath;
        try self.startManagement(.install_vsix, "", "", selected, false, true);
    }

    pub fn install(self: *ExtensionsWorkbenchService, extension: IExtension) !void {
        const url = extension.vsix_url orelse return error.ExtensionPackageUnavailable;
        return self.startManagementTarget(.install, extension.identifier, extension.version, url, extension.is_pre_release, false, extension.target_platform, extension.uuid, false);
    }

    pub fn uninstall(self: *ExtensionsWorkbenchService, identifier: []const u8) !void {
        const local = self.findLocal(identifier) orelse return error.ExtensionNotFound;
        if (local.is_builtin) return error.CannotUninstallBuiltin;
        var plan = try self.dependencyChangePlan(identifier, false);
        defer plan.deinit(self.allocator);
        if (plan.has_dependents) {
            try self.confirmDependencyChange(plan.ids.items, null);
        } else try self.startManagementMany(.uninstall, identifier, "", "", false, false, plan.ids.items, null, null, false);
    }

    fn startManagement(self: *ExtensionsWorkbenchService, operation: Operation, identifier: []const u8, version: []const u8, url: []const u8, prerelease: bool, pinned: bool) !void {
        return self.startManagementTarget(operation, identifier, version, url, prerelease, pinned, null, null, false);
    }

    fn startManagementTarget(self: *ExtensionsWorkbenchService, operation: Operation, identifier: []const u8, version: []const u8, url: []const u8, prerelease: bool, pinned: bool, target: ?[]const u8, uuid: ?[]const u8, require_verified: bool) !void {
        return self.startManagementMany(operation, identifier, version, url, prerelease, pinned, &.{identifier}, target, uuid, require_verified);
    }

    fn startManagementMany(self: *ExtensionsWorkbenchService, operation: Operation, identifier: []const u8, version: []const u8, url: []const u8, prerelease: bool, pinned: bool, identifiers: []const []const u8, target: ?[]const u8, uuid: ?[]const u8, require_verified: bool) !void {
        if (self.management_job != null) return error.ExtensionOperationInProgress;
        const window = self.window orelse return error.ExtensionManagementUnavailable;
        const location = self.user_location orelse return error.ExtensionsDirectoryUnavailable;
        const job = try self.allocator.create(ManagementJob);
        errdefer self.allocator.destroy(job);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const location_copy = try allocator.dupe(u8, location);
        const identifier_copy = try allocator.dupe(u8, identifier);
        const ids = try allocator.alloc([]const u8, identifiers.len);
        for (identifiers, ids) |id, *copy| copy.* = try allocator.dupe(u8, id);
        const version_copy = try allocator.dupe(u8, version);
        const url_copy = try allocator.dupe(u8, url);
        const system_location = if (self.system_location) |value| try allocator.dupe(u8, value) else null;
        const gallery_url = try allocator.dupe(u8, self.gallery_url orelse "");
        const target_platform = if (target) |platform| try allocator.dupe(u8, platform) else null;
        const uuid_copy = if (uuid) |value| try allocator.dupe(u8, value) else null;
        const verify_signature = if (self.update_configuration) |config| config.getBool("extensions.verifySignature", true) else true;
        job.* = .{ .service = self, .operation = operation, .arena = arena, .location = location_copy, .identifier = identifier_copy, .identifiers = ids, .version = version_copy, .url = url_copy, .system_location = system_location, .gallery_url = gallery_url, .prerelease = prerelease, .pinned = pinned, .target_platform = target_platform, .uuid = uuid_copy, .verify_signature = verify_signature, .require_verified = require_verified, .future = undefined, .completion = .{ .queue = window, .context = self, .run = applyManagement, .progress = true } };
        self.management_error = null;
        self.management_job = job;
        job.future = window.io.async(runManagement, .{job});
        self.on_change.fire({}) catch {};
    }

    fn applyManagement(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ExtensionsWorkbenchService = @ptrCast(@alignCast(context));
        const job = self.management_job orelse return false;
        self.management_job = null;
        defer job.deinit();
        const result = job.future.await(self.window.?.io);
        result catch |err| {
            self.management_error = err;
        };
        self.refresh() catch |err| {
            self.management_error = err;
            self.on_change.fire({}) catch {};
        };
        if (job.require_verified) self.scheduleAutoUpdate() else self.scheduleUpdateCheck(0);
        return true;
    }

    pub fn galleryExtensions(self: *const ExtensionsWorkbenchService) []const IExtension {
        return self.galleryExtensionsFor(.search);
    }

    pub fn galleryExtensionsFor(self: *const ExtensionsWorkbenchService, kind: GalleryKind) []const IExtension {
        const state = switch (kind) {
            .search => self.gallery_state,
            .popular => self.popular_state,
            .recommended => self.recommended_state,
            .lookup => self.lookup_state,
        };
        return if (state) |value| value.rows else &.{};
    }

    /// Consumes the gallery page on every outcome. Keep the old page alive
    /// through synchronous listener delivery just like local inventory refresh.
    pub fn setGalleryPage(self: *ExtensionsWorkbenchService, page: gallery.Page, append: bool, kind: GalleryKind) !void {
        var next: GalleryState = .{ .arena = .init(self.allocator), .page = page, .rows = &.{} };
        var owned = true;
        defer if (owned) next.deinit();
        const allocator = next.arena.allocator();
        const previous_rows = if (append) self.galleryExtensionsFor(kind) else &.{};
        const rows = try allocator.alloc(IExtension, previous_rows.len + page.extensions.len);
        var count: usize = 0;
        for (previous_rows) |row| {
            rows[count] = try row.clone(allocator);
            count += 1;
        }
        for (page.extensions) |entry| {
            if (entry.versions.len == 0) continue;
            const identifier = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ entry.publisher.publisherName, entry.extensionName });
            for (rows[0..count]) |row| {
                if (util.areSameExtensions(row.identifier, identifier)) break;
            } else {
                var local: ?IExtension = null;
                for (self.state.local) |extension| if (util.areSameExtensions(extension.identifier, identifier)) {
                    local = extension;
                    break;
                };
                const version = entry.selectVersion(null, if (local) |installed| installed.is_pre_release else false) orelse entry.selectVersion(null, true) orelse entry.versions[0];
                rows[count] = .{
                    .identifier = identifier,
                    .name = entry.extensionName,
                    .display_name = entry.displayName orelse entry.extensionName,
                    .description = entry.shortDescription orelse "",
                    .version = version.version,
                    .publisher = entry.publisher.displayName orelse entry.publisher.publisherName,
                    .categories = entry.categories orelse &.{},
                    .location = "",
                    .is_builtin = false,
                    .state = if (local != null) .Installed else .Uninstalled,
                    .enablement_state = if (local) |installed| installed.enablement_state else .EnabledGlobally,
                    .is_pre_release = version.isPreRelease(),
                    .install_count = entry.statistic("install"),
                    .rating = entry.statistic("averagerating"),
                    .rating_count = entry.statistic("ratingcount"),
                    .publisher_domain = entry.publisher.domain,
                    .publisher_verified = entry.publisher.domain != null and (entry.publisher.isDomainVerified orelse false),
                    .has_pre_release = entry.selectReleaseChannel(true) != null,
                    .manifest_url = version.asset("Microsoft.VisualStudio.Code.Manifest"),
                    .readme_url = version.asset("Microsoft.VisualStudio.Services.Content.Details"),
                    .changelog_url = version.asset("Microsoft.VisualStudio.Services.Content.Changelog"),
                    .vsix_url = if (version.isCompatible()) version.asset("Microsoft.VisualStudio.Services.VSIXPackage") else null,
                    .target_platform = version.targetPlatform,
                    .uuid = entry.extensionId,
                    .last_updated = if (entry.lastUpdated orelse version.lastUpdated) |timestamp| gallery.parseGalleryTimestamp(timestamp) else null,
                    .release_date = if (entry.releaseDate) |timestamp| gallery.parseGalleryTimestamp(timestamp) else null,
                    .executes_code = if (version.property("Microsoft.VisualStudio.Code.ExecutesCode")) |value| std.mem.eql(u8, value, "true") else null,
                };
                count += 1;
            }
        }
        next.rows = rows[0..count];
        const slot = switch (kind) {
            .search => &self.gallery_state,
            .popular => &self.popular_state,
            .recommended => &self.recommended_state,
            .lookup => &self.lookup_state,
        };
        var previous = slot.*;
        slot.* = next;
        owned = false;
        defer if (previous) |*state| state.deinit();
        try self.on_change.fire({});
    }

    fn updateGalleryLocalState(self: *ExtensionsWorkbenchService) void {
        const sources = [_][]IExtension{ if (self.gallery_state) |state| state.rows else &.{}, if (self.popular_state) |state| state.rows else &.{}, if (self.recommended_state) |state| state.rows else &.{}, if (self.lookup_state) |state| state.rows else &.{}, if (self.updates) |updates| updates.rows else &.{} };
        for (sources) |rows| for (rows) |*row| {
            const local = self.findLocal(row.identifier);
            row.state = if (local != null) .Installed else .Uninstalled;
            row.enablement_state = if (local) |extension| extension.enablement_state else .EnabledGlobally;
        };
    }

    pub fn isEnabled(self: *const ExtensionsWorkbenchService, identifier: []const u8) bool {
        return self.enablement.isEnabled(identifier);
    }

    const DependencyChangePlan = struct {
        ids: std.ArrayList([]const u8) = .empty,
        has_dependents: bool = false,
        fn deinit(self: *DependencyChangePlan, allocator: Allocator) void {
            self.ids.deinit(allocator);
        }
    };

    fn containsIdentifier(ids: []const []const u8, id: []const u8) bool {
        for (ids) |existing| if (util.areSameExtensions(existing, id)) return true;
        return false;
    }

    fn collectPack(self: *ExtensionsWorkbenchService, id: []const u8, plan: *DependencyChangePlan) anyerror!void {
        const extension = self.state.inventory.find(id) orelse return;
        if (containsIdentifier(plan.ids.items, extension.identifier)) return;
        try plan.ids.append(self.allocator, extension.identifier);
        for (dependencies(extension, "extensionPack")) |member| {
            if (member != .string) continue;
            const packed_extension = self.state.inventory.find(member.string) orelse continue;
            if (!packed_extension.isBuiltin()) try self.collectPack(packed_extension.identifier, plan);
        }
    }

    fn dependencyChangePlan(self: *ExtensionsWorkbenchService, identifier: []const u8, disable: bool) !DependencyChangePlan {
        var plan: DependencyChangePlan = .{};
        errdefer plan.deinit(self.allocator);
        try self.collectPack(identifier, &plan);
        var changed = true;
        while (changed) {
            changed = false;
            for (self.state.inventory.all, self.state.local) |extension, local| {
                if (containsIdentifier(plan.ids.items, extension.identifier)) continue;
                if (disable and !local.isEnabled()) continue;
                for (dependencies(extension, "extensionDependencies")) |dependency| {
                    if (dependency != .string or !containsIdentifier(plan.ids.items, dependency.string)) continue;
                    if (!disable and extension.isBuiltin()) return error.BuiltinExtensionDependsOnExtension;
                    plan.has_dependents = true;
                    changed = true;
                    try self.collectPack(extension.identifier, &plan);
                    break;
                }
            }
        }
        return plan;
    }

    fn confirmDependencyChange(self: *ExtensionsWorkbenchService, identifiers: []const []const u8, state: ?EnablementState) !void {
        if (self.pending_dialog != null) return error.ExtensionOperationInProgress;
        const dialog = self.dialog_service orelse return error.ExtensionHasDependents;
        const pending = try self.allocator.create(PendingDependencyChange);
        errdefer self.allocator.destroy(pending);
        pending.* = .{ .owner = self, .arena = .init(self.allocator), .identifiers = &.{}, .state = state };
        errdefer pending.arena.deinit();
        const allocator = pending.arena.allocator();
        const ids = try allocator.alloc([]const u8, identifiers.len);
        for (identifiers, ids) |id, *copy| copy.* = try allocator.dupe(u8, id);
        pending.identifiers = ids;
        const detail = try std.mem.join(allocator, ", ", ids);
        self.pending_dialog = try dialog.confirm(.{ .message = if (state != null) "Other extensions depend on this extension. Disable all of them?" else "Other extensions depend on this extension. Uninstall all of them?", .detail = detail, .primary_button = if (state != null) "Disable All" else "Uninstall All", .initial_focus = 1 }, .{ .context = pending, .complete = PendingDependencyChange.complete, .dispose = PendingDependencyChange.dispose });
    }

    /// User-facing enablement actions follow the upstream dependency/pack
    /// confirmation path. The model-only setter remains available to callers
    /// that have already obtained consent or are testing the derived state.
    pub fn requestEnablement(self: *ExtensionsWorkbenchService, identifier: []const u8, state: EnablementState) !bool {
        if (state == .EnabledGlobally or state == .EnabledWorkspace) return self.setEnablement(identifier, state);
        var plan = try self.dependencyChangePlan(identifier, true);
        defer plan.deinit(self.allocator);
        if (plan.has_dependents) {
            try self.confirmDependencyChange(plan.ids.items, state);
            return false;
        }
        return self.applyDisablement(plan.ids.items, state);
    }

    fn applyDisablement(self: *ExtensionsWorkbenchService, ids: []const []const u8, state: EnablementState) !bool {
        var changed = false;
        for (ids) |id| if (try self.enablement.setEnablement(id, state)) {
            changed = true;
        };
        if (changed) try self.refreshEnablement();
        return changed;
    }

    fn enableRecursively(self: *ExtensionsWorkbenchService, identifier: []const u8, state: EnablementState, visited: *std.StringHashMap(void)) anyerror!bool {
        const extension = self.state.inventory.find(identifier) orelse return false;
        if (visited.contains(extension.identifier)) return false;
        try visited.put(extension.identifier, {});
        var changed = try self.enablement.setEnablement(extension.identifier, state);
        for ([_][]const u8{ "extensionDependencies", "extensionPack" }) |key| {
            for (dependencies(extension, key)) |entry| {
                if (entry != .string) continue;
                if (self.findLocal(entry.string)) |dependency| {
                    if (!dependency.isEnabled() and try self.enableRecursively(entry.string, state, visited)) changed = true;
                }
            }
        }
        return changed;
    }

    pub fn setEnablement(self: *ExtensionsWorkbenchService, identifier: []const u8, state: EnablementState) !bool {
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();
        const changed = if (state == .EnabledGlobally or state == .EnabledWorkspace)
            try self.enableRecursively(identifier, state, &visited)
        else
            try self.enablement.setEnablement(identifier, state);
        if (changed) try self.refreshEnablement();
        return changed;
    }

    pub fn userExtensions(self: *const ExtensionsWorkbenchService) []const scanner.ScannedExtension {
        return self.state.inventory.user;
    }

    /// The raw installed system scan, retained for inventory reporting.
    pub fn systemExtensions(self: *const ExtensionsWorkbenchService) []const scanner.ScannedExtension {
        return self.state.inventory.system;
    }

    /// Descriptions of the enabled extensions in merged order; the declarative
    /// registry, theme registration and local extension host consume this.
    pub fn enabledDescriptions(self: *const ExtensionsWorkbenchService) []const *const scanner.ScannedExtension {
        return self.state.enabled.items;
    }

    /// Rescans the locations and swaps in the new model. The previous
    /// generation stays allocated until the listeners have rebuilt, because a
    /// view may still hold pointers into it while handling the change event.
    pub fn refresh(self: *ExtensionsWorkbenchService) !void {
        const state = try self.scan();
        const previous = self.replaceState(state);
        // Preserve the previous generation until both registry and view
        // listeners have consumed this event.
        self.on_did_change_enabled_descriptions.fire({}) catch {};
        self.updateGalleryLocalState();
        self.on_change.fire({}) catch |err| {
            self.freeState(previous);
            return err;
        };
        self.freeState(previous);
    }
};

pub const extensions_workbench_service_id = @import("../../../../platform/instantiation/common/instantiation.zig").ServiceIdentifier(ExtensionsWorkbenchService, "extensionsWorkbenchService");

/// The upstream unattended-update conditions: only enabled, unpinned user
/// extensions with a newer compatible version. Publisher/UUID changes and
/// updates introducing executable code require a manual action. The install
/// transaction independently enforces successful repository verification.
pub fn shouldAutoUpdate(local: IExtension, remote: IExtension, now: i64, delay_hours: f64) bool {
    return autoUpdatePolicy(true, &.{}, local) and isEligibleUpdate(local, remote, now, delay_hours);
}

fn hasAutoUpdateEntry(entries: []const std.json.Value, value: []const u8) bool {
    for (entries) |entry| if (entry == .string and std.ascii.eqlIgnoreCase(entry.string, value)) return true;
    return false;
}

pub fn autoUpdatePolicy(global_enabled: bool, entries: []const std.json.Value, extension: IExtension) bool {
    if (extension.is_builtin) return false;
    if (global_enabled) return !extension.pinned and extension.isEnabled() and !hasAutoUpdateEntry(entries, extension.identifier);
    if (hasAutoUpdateEntry(entries, extension.identifier)) return true;
    if (!hasAutoUpdateEntry(entries, extension.publisherIdentifier())) return false;
    for (entries) |entry| if (entry == .string and entry.string.len > 0 and entry.string[0] == '-' and std.ascii.eqlIgnoreCase(entry.string[1..], extension.identifier)) return false;
    return true;
}

fn isEligibleUpdate(local: IExtension, remote: IExtension, now: i64, delay_hours: f64) bool {
    if (remote.vsix_url == null) return false;
    if (remote.is_pre_release and !local.is_pre_release) return false;
    const current = std.SemanticVersion.parse(local.version) catch return false;
    const candidate = std.SemanticVersion.parse(remote.version) catch return false;
    if (candidate.order(current) != .gt) return false;
    if (local.uuid) |uuid| {
        if (!std.ascii.eqlIgnoreCase(uuid, remote.uuid orelse return false)) return false;
    }
    if (!(local.executes_code orelse false) and (remote.executes_code orelse true)) return false;
    if (remote.last_updated) |published| {
        if (published > 0 and now >= published and @as(f64, @floatFromInt(now - published)) < delay_hours * 60 * 60 * 1000) return false;
    }
    return true;
}
