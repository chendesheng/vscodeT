// Port of the local-extension inventory in
// `src/vs/workbench/contrib/extensions/browser/extensionsWorkbenchService.ts`.
//
// Terminal adaptation: the extension host servers, gallery, install/update
// flows, extension packs, recommendations and running-extension state are not
// ported. The service owns the scanned local inventory (installed built-ins +
// the VS Code user extensions directory), the `IExtension` view model and the
// enablement state, and emits `onChange` when either changes. Enablement is
// global and applies to contributions/extension-host startup on the next
// launch; the TUI has no reload command.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const scanner = @import("../../../../platform/extensionManagement/common/extensionsScannerService.zig");
const util = @import("../../../../platform/extensionManagement/common/extensionManagementUtil.zig");
const enablement_mod = @import("../../../services/extensionManagement/browser/extensionEnablementService.zig");
const model = @import("../common/extensions.zig");
const IExtension = model.IExtension;
const EnablementState = model.EnablementState;

pub const Options = struct {
    system_location: ?[]const u8 = null,
    user_location: ?[]const u8 = null,
    enablement: *enablement_mod.ExtensionEnablementService,
};

/// One immutable generation of the scanned inventory. `local` borrows the
/// manifest strings owned by `inventory`; the pair is replaced together.
const ModelState = struct {
    inventory: scanner.ScanResult,
    local: []IExtension,
    /// Descriptions whose enablement state is enabled, in merged order.
    enabled: std.array_list.Managed(*const scanner.ScannedExtension),
};

pub const ExtensionsWorkbenchService = struct {
    allocator: Allocator,
    io: std.Io,
    system_location: ?[]u8 = null,
    user_location: ?[]u8 = null,
    state: ModelState,
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
        self.freeState(self.state);
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
        for (inventory.all, 0..) |extension, index| local[index] = .{
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
        };

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

    pub fn find(self: *const ExtensionsWorkbenchService, identifier: []const u8) ?*const IExtension {
        for (self.state.local) |*extension| {
            if (util.areSameExtensions(extension.identifier, identifier)) return extension;
        }
        return null;
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
        self.on_change.fire({}) catch |err| {
            self.freeState(previous);
            return err;
        };
        self.freeState(previous);
    }
};
