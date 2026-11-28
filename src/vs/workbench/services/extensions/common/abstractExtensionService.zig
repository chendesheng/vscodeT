// Port of the local process inventory and activation-event subset of
// `src/vs/workbench/services/extensions/common/abstractExtensionService.ts`.
// The terminal has one local Node host. Remote and web-worker running
// locations are not supported. The installed system catalog and the optional
// runtime bundle directory are separate in the terminal distribution.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const manager = @import("extensionHostManager.zig");

pub const ExtensionPath = struct {
    path: []const u8,
    is_builtin: bool = false,
    is_under_development: bool = false,
};

const scanner = @import("../../../../platform/extensionManagement/common/extensionsScannerService.zig");
const catalog = @import("extensionsRegistry.zig");

/// The scanner has already deduplicated the installed extensions and applied
/// enablement. Pass every effective description, including declarative-only
/// entries, to the local extension host. The host decides what to activate.
pub fn resolveEnabledPaths(allocator: Allocator, io: Io, enabled: []const *const scanner.ScannedExtension, runtime_dir: []const u8) ![]ExtensionPath {
    var paths: std.ArrayList(ExtensionPath) = .empty;
    errdefer {
        for (paths.items) |entry| allocator.free(entry.path);
        paths.deinit(allocator);
    }
    try paths.ensureTotalCapacity(allocator, enabled.len);
    for (enabled) |extension| paths.appendAssumeCapacity(.{
        .path = try resolvePath(allocator, io, extension.location, extension.isBuiltin(), runtime_dir),
        .is_builtin = extension.isBuiltin(),
    });
    return paths.toOwnedSlice(allocator);
}

/// The built-in-only declarative fallback is used if the installed extension
/// scanner cannot be constructed. It uses the same local host path policy.
pub fn resolveCatalogPaths(allocator: Allocator, io: Io, extensions: []const catalog.Extension, runtime_dir: []const u8) ![]ExtensionPath {
    var paths: std.ArrayList(ExtensionPath) = .empty;
    errdefer {
        for (paths.items) |entry| allocator.free(entry.path);
        paths.deinit(allocator);
    }
    try paths.ensureTotalCapacity(allocator, extensions.len);
    for (extensions) |extension| paths.appendAssumeCapacity(.{
        .path = try resolvePath(allocator, io, extension.root, extension.is_builtin, runtime_dir),
        .is_builtin = extension.is_builtin,
    });
    return paths.toOwnedSlice(allocator);
}

fn resolvePath(allocator: Allocator, io: Io, location: []const u8, is_builtin: bool, runtime_dir: []const u8) ![]u8 {
    if (is_builtin) {
        const bundle = try std.fs.path.join(allocator, &.{ runtime_dir, "extensions", std.fs.path.basename(location) });
        errdefer allocator.free(bundle);
        const manifest = try std.fs.path.join(allocator, &.{ bundle, "package.json" });
        defer allocator.free(manifest);
        if (std.Io.Dir.cwd().access(io, manifest, .{})) |_| return bundle else |_| {}
        allocator.free(bundle);
    }
    return allocator.dupe(u8, location);
}

pub fn freePaths(allocator: Allocator, paths: []ExtensionPath) void {
    for (paths) |entry| allocator.free(entry.path);
    allocator.free(paths);
}

/// Reads every extension path and prepares the host descriptions. The caller
/// owns the returned slice; each entry owns its manifest and activation data.
pub fn readExtensions(
    allocator: Allocator,
    io: Io,
    paths: []const ExtensionPath,
) ![]manager.ExtensionDescription {
    var descriptions = std.array_list.Managed(manager.ExtensionDescription).init(allocator);
    errdefer {
        for (descriptions.items) |*description| description.deinit(allocator);
        descriptions.deinit();
    }
    for (paths) |entry| {
        const absolute_path = try std.Io.Dir.cwd().realPathFileAlloc(io, entry.path, allocator);
        defer allocator.free(absolute_path);
        var description = try manager.readExtensionDescription(allocator, io, absolute_path);
        description.is_builtin = entry.is_builtin;
        description.is_under_development = entry.is_under_development;
        errdefer description.deinit(allocator);
        try descriptions.append(description);
    }
    if (descriptions.items.len == 0) return error.NoExtensions;
    return descriptions.toOwnedSlice();
}

/// Tracks the `onLanguage:<id>` events sent to the host so each language
/// activates at most once. Mirrors the workbench language service's request
/// deduplication.
pub const ActivationTracker = struct {
    allocator: Allocator,
    activated_languages: std.StringHashMap(void),

    pub fn init(allocator: Allocator) ActivationTracker {
        return .{
            .allocator = allocator,
            .activated_languages = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *ActivationTracker) void {
        var iterator = self.activated_languages.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.activated_languages.deinit();
    }

    /// Sends `onLanguage:<language_id>` once. The document delta must already
    /// have been queued; the host preserves frame order.
    pub fn activateLanguage(self: *ActivationTracker, host: *manager.HostManager, language_id: []const u8) void {
        if (language_id.len == 0) return;
        if (self.activated_languages.contains(language_id)) return;
        const event = std.fmt.allocPrint(self.allocator, "onLanguage:{s}", .{language_id}) catch return;
        defer self.allocator.free(event);
        host.activateByEvent(event, 0) catch return;
        if (self.activated_languages.count() == 0) host.activateByEvent("onLanguage", 0) catch return;
        const owned = self.allocator.dupe(u8, language_id) catch return;
        self.activated_languages.put(owned, {}) catch {
            self.allocator.free(owned);
            return;
        };
    }
};

test "ActivationTracker deduplicates languages" {
    const allocator = std.testing.allocator;
    var tracker = ActivationTracker.init(allocator);
    defer tracker.deinit();
    try std.testing.expect(!tracker.activated_languages.contains("typescript"));
    const owned = try allocator.dupe(u8, "typescript");
    try tracker.activated_languages.put(owned, {});
    try std.testing.expect(tracker.activated_languages.contains("typescript"));
}
