// Port of the service/config portion of
// `src/vs/workbench/browser/parts/editor/breadcrumbs.ts`.
//
// The browser service maps an editor group id to its breadcrumbs widget and
// exposes configuration stubs bound to `IConfigurationService`. The terminal
// workbench has one active breadcrumb row, so the map holds an opaque control
// pointer; the control registers/unregisters itself as the active group
// changes.
//
// Terminal adaptation: the configuration service has no registered defaults
// for the editor part options, so `Settings.load` applies upstream's defaults
// when a key is absent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const GroupIdentifier = @import("../../../common/editor.zig").GroupIdentifier;
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;

pub const height: usize = 1;

pub const PathMode = enum { on, off, last };

pub const Settings = struct {
    enabled: bool = true,
    file_path: PathMode = .on,
    symbol_path: PathMode = .on,
    icons: bool = true,

    /// Reads the terminal breadcrumb settings with upstream defaults.
    pub fn load(configuration: ?*ConfigurationService) Settings {
        var settings = Settings{};
        const config = configuration orelse return settings;
        if (config.getValue("breadcrumbs.enabled", .{})) |value| {
            if (value.* == .bool) settings.enabled = value.bool;
        }
        if (config.getValue("breadcrumbs.filePath", .{})) |value| {
            settings.file_path = pathMode(value.*, .on);
        }
        if (config.getValue("breadcrumbs.symbolPath", .{})) |value| {
            settings.symbol_path = pathMode(value.*, .on);
        }
        if (config.getValue("breadcrumbs.icons", .{})) |value| {
            if (value.* == .bool) settings.icons = value.bool;
        }
        return settings;
    }
};

fn pathMode(value: std.json.Value, fallback: PathMode) PathMode {
    if (value != .string) return fallback;
    if (std.mem.eql(u8, value.string, "on")) return .on;
    if (std.mem.eql(u8, value.string, "off")) return .off;
    if (std.mem.eql(u8, value.string, "last")) return .last;
    return fallback;
}

/// Upstream `IBreadcrumbsService`. The value is opaque so this file does not
/// depend on the control, which depends on the model.
pub const BreadcrumbsService = struct {
    allocator: Allocator,
    widgets: std.AutoHashMap(GroupIdentifier, *anyopaque),

    const Registration = struct {
        service: *BreadcrumbsService,
        group: GroupIdentifier,
    };

    pub fn init(allocator: Allocator) BreadcrumbsService {
        return .{
            .allocator = allocator,
            .widgets = std.AutoHashMap(GroupIdentifier, *anyopaque).init(allocator),
        };
    }

    pub fn deinit(self: *BreadcrumbsService) void {
        self.widgets.deinit();
    }

    pub fn register(self: *BreadcrumbsService, group: GroupIdentifier, widget: *anyopaque) !IDisposable {
        if (self.widgets.contains(group)) return error.GroupAlreadyRegistered;
        try self.widgets.put(group, widget);
        const registration = try self.allocator.create(Registration);
        registration.* = .{ .service = self, .group = group };
        return .{ .context = registration, .disposeFn = disposeRegistration };
    }

    fn disposeRegistration(context: *anyopaque) void {
        const registration: *Registration = @ptrCast(@alignCast(context));
        _ = registration.service.widgets.remove(registration.group);
        registration.service.allocator.destroy(registration);
    }

    pub fn getWidget(self: *const BreadcrumbsService, group: GroupIdentifier) ?*anyopaque {
        return self.widgets.get(group);
    }
};

test "BreadcrumbsService: register and unregister a group widget" {
    var service = BreadcrumbsService.init(std.testing.allocator);
    defer service.deinit();

    var widget: u8 = 0;
    const registration = try service.register(7, @ptrCast(&widget));
    try std.testing.expect(service.getWidget(7) != null);
    registration.dispose();
    try std.testing.expect(service.getWidget(7) == null);
}

test "Breadcrumbs settings use upstream defaults" {
    const settings = Settings.load(null);
    try std.testing.expect(settings.enabled);
    try std.testing.expectEqual(PathMode.on, settings.file_path);
    try std.testing.expectEqual(PathMode.on, settings.symbol_path);
    try std.testing.expect(settings.icons);
}
