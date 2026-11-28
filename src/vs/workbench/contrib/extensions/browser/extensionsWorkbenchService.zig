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
const EnablementState = model.EnablementState;

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

const Operation = enum { install, uninstall };
const ManagementJob = struct {
    service: *ExtensionsWorkbenchService,
    operation: Operation,
    arena: std.heap.ArenaAllocator,
    location: []const u8,
    identifier: []const u8,
    version: []const u8,
    url: []const u8,
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
        .install => try dispatch.workerCall(io, management.installFromGallery, .{ job.service.allocator, dispatch.backingIo(io), job.location, job.url, job.identifier, job.version }),
        .uninstall => try dispatch.workerCall(io, management.uninstall, .{ job.service.allocator, dispatch.backingIo(io), job.location, job.identifier }),
    }
}

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
    management_job: ?*ManagementJob = null,
    management_error: ?anyerror = null,
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
            };
        }

        var enabled: std.array_list.Managed(*const scanner.ScannedExtension) = .init(self.allocator);
        errdefer enabled.deinit();
        for (inventory.all) |extension| {
            if (!self.enablement.isEnabled(extension.identifier)) continue;
            try enabled.append(extension);
        }

        return .{ .inventory = inventory, .local = local, .enabled = enabled };
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

    pub fn detachWindow(self: *ExtensionsWorkbenchService) void {
        if (self.management_job) |job| {
            self.management_job = null;
            job.future.cancel(self.window.?.io) catch {};
            job.completion.schedule(null);
            job.deinit();
        }
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

    pub fn operationState(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?model.ExtensionState {
        const job = self.management_job orelse return null;
        if (!util.areSameExtensions(job.identifier, identifier)) return null;
        return switch (job.operation) {
            .install => .Installing,
            .uninstall => .Uninstalling,
        };
    }

    pub fn install(self: *ExtensionsWorkbenchService, extension: IExtension) !void {
        const url = extension.vsix_url orelse return error.ExtensionPackageUnavailable;
        return self.startManagement(.install, extension.identifier, extension.version, url);
    }

    pub fn uninstall(self: *ExtensionsWorkbenchService, identifier: []const u8) !void {
        const local = self.findLocal(identifier) orelse return error.ExtensionNotFound;
        if (local.is_builtin) return error.CannotUninstallBuiltin;
        return self.startManagement(.uninstall, identifier, "", "");
    }

    fn startManagement(self: *ExtensionsWorkbenchService, operation: Operation, identifier: []const u8, version: []const u8, url: []const u8) !void {
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
        job.* = .{ .service = self, .operation = operation, .arena = arena, .location = location_copy, .identifier = identifier_copy, .version = version_copy, .url = url_copy, .future = undefined, .completion = .{ .queue = window, .context = self, .run = applyManagement, .progress = true } };
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
            var version = entry.versions[0];
            for (entry.versions) |candidate| if (candidate.isCompatible()) {
                version = candidate;
                break;
            };
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

    pub fn setEnablement(self: *ExtensionsWorkbenchService, identifier: []const u8, state: EnablementState) !bool {
        if (!try self.enablement.setEnablement(identifier, state)) return false;
        for (self.state.local) |*extension| {
            if (!util.areSameExtensions(extension.identifier, identifier)) continue;
            extension.enablement_state = state;
        }
        if (state.isEnabled()) {
            if (self.state.inventory.find(identifier)) |extension| {
                var present = false;
                for (self.state.enabled.items) |entry| {
                    if (entry == extension) {
                        present = true;
                        break;
                    }
                }
                if (!present) try self.state.enabled.append(extension);
            }
        } else {
            var index: usize = 0;
            while (index < self.state.enabled.items.len) {
                if (util.areSameExtensions(self.state.enabled.items[index].identifier, identifier)) {
                    _ = self.state.enabled.orderedRemove(index);
                    continue;
                }
                index += 1;
            }
        }
        self.updateGalleryLocalState();
        try self.on_change.fire({});
        return true;
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
