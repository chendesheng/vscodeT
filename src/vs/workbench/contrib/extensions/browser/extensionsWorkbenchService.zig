// Port of `src/vs/workbench/contrib/extensions/browser/extensionsWorkbenchService.ts`.
// Owns the local and gallery inventories, enablement, installation operations
// and onChange delivery. The terminal uses a single local server and scans
// the effective user directory; changes to the startup contribution registry
// and running extension host still require a process restart. Automatic
// update scheduling, full profile management and runtime reconciliation are
// not yet ported.
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
const quick = @import("../../../../platform/quickinput/common/quickInput.zig");
const EnablementState = model.EnablementState;
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

const GalleryState = struct {
    arena: std.heap.ArenaAllocator,
    page: gallery.Page,
    rows: []IExtension,

    fn deinit(self: *GalleryState) void {
        self.arena.deinit();
        self.page.deinit();
    }
};

const Operation = enum { install, uninstall, install_vsix };
const ManagementJob = struct {
    service: *ExtensionsWorkbenchService,
    operation: Operation,
    arena: std.heap.ArenaAllocator,
    location: []const u8,
    identifier: []const u8,
    version: []const u8,
    url: []const u8,
    system_location: ?[]const u8,
    gallery_url: []const u8,
    prerelease: bool,
    pinned: bool,
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
        .install => try dispatch.workerCall(io, management.installFromGallery, .{ job.service.allocator, dispatch.backingIo(io), job.location, job.system_location, job.gallery_url, job.url, job.identifier, job.version, job.prerelease, job.pinned }),
        .install_vsix => try dispatch.workerCall(io, management.installVSIXFile, .{ job.service.allocator, dispatch.backingIo(io), job.location, job.system_location, job.gallery_url, job.url }),
        .uninstall => try dispatch.workerCall(io, management.uninstall, .{ job.service.allocator, dispatch.backingIo(io), job.location, job.identifier }),
    }
}

const VersionJob = struct {
    service: *ExtensionsWorkbenchService,
    input: quick.IQuickInputService,
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
            try service.startManagement(.install, self.identifier, version.version, url, version.isPreRelease(), true);
            return;
        }
    }
};

pub const ExtensionsWorkbenchService = struct {
    allocator: Allocator,
    io: std.Io,
    system_location: ?[]u8 = null,
    user_location: ?[]u8 = null,
    state: ModelState,
    gallery_url: ?[]u8 = null,
    gallery_state: ?GalleryState = null,
    window: ?*dispatch.Queue = null,
    workspace: ?*@import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService = null,
    workspace_listener: ?@import("../../../../base/common/event.zig").SignalSubscription = null,
    management_job: ?*ManagementJob = null,
    management_error: ?anyerror = null,
    version_job: ?*VersionJob = null,
    version_picker: ?*VersionPicker = null,
    quick_input: ?quick.IQuickInputService = null,
    runtime: ?RuntimeInventory = null,
    restart_host: ?struct { context: *anyopaque, restart: *const fn (*anyopaque) anyerror!void } = null,
    enablement: *enablement_mod.ExtensionEnablementService,
    on_change: Emitter(void),

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
            .on_change = Emitter(void).init(allocator),
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
        if (self.runtime) |*runtime| runtime.deinit();
        if (self.gallery_state) |*state| state.deinit();
        if (self.gallery_url) |url| self.allocator.free(url);
        self.on_change.deinit();
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
        self.updateGalleryLocalState();
        try self.on_change.fire({});
    }

    /// Called by the local host owner only after accepting the new inventory.
    pub fn recordRuntime(self: *ExtensionsWorkbenchService) !void {
        const next = try RuntimeInventory.init(self.allocator, self.enabledDescriptions());
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

    pub fn findLocal(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?*const IExtension {
        for (self.state.local) |*extension| {
            if (util.areSameExtensions(extension.identifier, identifier)) return extension;
        }
        return null;
    }

    pub fn find(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?*const IExtension {
        if (self.findLocal(identifier)) |extension| return extension;
        if (self.gallery_state) |state| for (state.rows) |*extension| {
            if (util.areSameExtensions(extension.identifier, identifier)) return extension;
        };
        return null;
    }

    pub fn attachWindow(self: *ExtensionsWorkbenchService, window: *dispatch.Queue) void {
        self.window = window;
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
    }

    pub fn detachWindow(self: *ExtensionsWorkbenchService) void {
        self.cancelVersions();
        if (self.version_picker) |picker| picker.owner = null;
        self.version_picker = null;
        self.quick_input = null;
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

    pub fn galleryInfo(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?*const IExtension {
        for (self.galleryExtensions()) |*extension| if (util.areSameExtensions(extension.identifier, identifier)) return extension;
        return null;
    }

    pub fn availableUpdate(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?*const IExtension {
        const local = self.findLocal(identifier) orelse return null;
        if (local.is_builtin) return null;
        const remote = self.galleryInfo(identifier) orelse return null;
        if (remote.vsix_url == null) return null;
        const current = std.SemanticVersion.parse(local.version) catch return null;
        const candidate = std.SemanticVersion.parse(remote.version) catch return null;
        return if (candidate.order(current) == .gt) remote else null;
    }

    pub fn showVersions(self: *ExtensionsWorkbenchService, identifier: []const u8) !void {
        const window = self.window orelse return error.ExtensionManagementUnavailable;
        const input = self.quick_input orelse return error.QuickInputUnavailable;
        const url = self.gallery_url orelse return error.GalleryUnavailable;
        self.cancelVersions();
        const owned_id = try self.allocator.dupe(u8, identifier);
        errdefer self.allocator.free(owned_id);
        const owned_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned_url);
        const job = try self.allocator.create(VersionJob);
        job.* = .{ .service = self, .input = input, .identifier = owned_id, .url = owned_url, .completion = .{ .queue = window, .context = self, .run = applyVersions, .progress = true }, .future = undefined };
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
        self.presentVersions(job, page) catch |err| {
            self.management_error = err;
            self.on_change.fire({}) catch {};
        };
        return true;
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
                    try choices.append(allocator, .{ .version = owned_version, .files = assets, .properties = properties });
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
        if (!util.areSameExtensions(job.identifier, identifier)) return null;
        return switch (job.operation) {
            .install, .install_vsix => .Installing,
            .uninstall => .Uninstalling,
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
        return self.startManagement(.install, extension.identifier, extension.version, url, extension.is_pre_release, false);
    }

    pub fn uninstall(self: *ExtensionsWorkbenchService, identifier: []const u8) !void {
        const local = self.findLocal(identifier) orelse return error.ExtensionNotFound;
        if (local.is_builtin) return error.CannotUninstallBuiltin;
        return self.startManagement(.uninstall, identifier, "", "", false, false);
    }

    fn startManagement(self: *ExtensionsWorkbenchService, operation: Operation, identifier: []const u8, version: []const u8, url: []const u8, prerelease: bool, pinned: bool) !void {
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
        const version_copy = try allocator.dupe(u8, version);
        const url_copy = try allocator.dupe(u8, url);
        const system_location = if (self.system_location) |value| try allocator.dupe(u8, value) else null;
        const gallery_url = try allocator.dupe(u8, self.gallery_url orelse "");
        job.* = .{ .service = self, .operation = operation, .arena = arena, .location = location_copy, .identifier = identifier_copy, .version = version_copy, .url = url_copy, .system_location = system_location, .gallery_url = gallery_url, .prerelease = prerelease, .pinned = pinned, .future = undefined, .completion = .{ .queue = window, .context = self, .run = applyManagement, .progress = true } };
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
        return true;
    }

    pub fn galleryExtensions(self: *const ExtensionsWorkbenchService) []const IExtension {
        return if (self.gallery_state) |state| state.rows else &.{};
    }

    /// Consumes the gallery page on every outcome. Keep the old page alive
    /// through synchronous listener delivery just like local inventory refresh.
    pub fn setGalleryPage(self: *ExtensionsWorkbenchService, page: gallery.Page) !void {
        var next: GalleryState = .{ .arena = .init(self.allocator), .page = page, .rows = &.{} };
        var owned = true;
        defer if (owned) next.deinit();
        const allocator = next.arena.allocator();
        const rows = try allocator.alloc(IExtension, page.extensions.len);
        var count: usize = 0;
        for (page.extensions) |entry| {
            if (entry.versions.len == 0) continue;
            const version = entry.selectVersion(null, false) orelse entry.selectVersion(null, true) orelse entry.versions[0];
            const identifier = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ entry.publisher.publisherName, entry.extensionName });
            var local: ?IExtension = null;
            for (self.state.local) |extension| if (util.areSameExtensions(extension.identifier, identifier)) {
                local = extension;
                break;
            };
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
                .manifest_url = version.asset("Microsoft.VisualStudio.Code.Manifest"),
                .readme_url = version.asset("Microsoft.VisualStudio.Services.Content.Details"),
                .changelog_url = version.asset("Microsoft.VisualStudio.Services.Content.Changelog"),
                .vsix_url = if (version.isCompatible()) version.asset("Microsoft.VisualStudio.Services.VSIXPackage") else null,
            };
            count += 1;
        }
        next.rows = rows[0..count];
        var previous = self.gallery_state;
        self.gallery_state = next;
        owned = false;
        defer if (previous) |*state| state.deinit();
        try self.on_change.fire({});
    }

    fn updateGalleryLocalState(self: *ExtensionsWorkbenchService) void {
        if (self.gallery_state) |*state| for (state.rows) |*row| {
            const local = self.findLocal(row.identifier);
            row.state = if (local != null) .Installed else .Uninstalled;
            row.enablement_state = if (local) |extension| extension.enablement_state else .EnabledGlobally;
        };
    }

    pub fn isEnabled(self: *const ExtensionsWorkbenchService, identifier: []const u8) bool {
        return self.enablement.isEnabled(identifier);
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
        self.updateGalleryLocalState();
        self.on_change.fire({}) catch |err| {
            self.freeState(previous);
            return err;
        };
        self.freeState(previous);
    }
};

pub const extensions_workbench_service_id = @import("../../../../platform/instantiation/common/instantiation.zig").ServiceIdentifier(ExtensionsWorkbenchService, "extensionsWorkbenchService");
