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

/// The effective extension registry accepted by the local runtime. Keep an
/// owned description identity after the installed inventory has been replaced.
/// The terminal currently mounts declarative extension points at window startup;
/// those changes require a window restart rather than only a host restart.
pub const RuntimeInventory = struct {
    const util = @import("../../../../platform/extensionManagement/common/extensionManagementUtil.zig");
    pub const Action = enum { RestartExtensions, ReloadWindow };
    const Entry = struct { identifier: []const u8, version: []const u8, location: []const u8, declarative: bool };
    arena: std.heap.ArenaAllocator,
    entries: []Entry,

    pub fn init(allocator: Allocator, descriptions: []const *const scanner.ScannedExtension) !RuntimeInventory {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const scratch = arena.allocator();
        const entries = try scratch.alloc(Entry, descriptions.len);
        for (descriptions, entries) |description, *entry| entry.* = .{
            .identifier = try scratch.dupe(u8, description.identifier),
            .version = try scratch.dupe(u8, description.version),
            .location = try scratch.dupe(u8, description.location),
            .declarative = hasWindowContributions(description.*),
        };
        return .{ .arena = arena, .entries = entries };
    }

    pub fn deinit(self: *RuntimeInventory) void {
        self.arena.deinit();
    }

    fn hasWindowContributions(description: scanner.ScannedExtension) bool {
        const manifest = description.manifest.value;
        if (manifest != .object) return false;
        const contributes = manifest.object.get("contributes") orelse return false;
        if (contributes != .object) return false;
        // These extension points are mounted in the startup registry and have
        // no removal/replacement contract yet. Do not report a host-only
        // restart as sufficient for changes to their definitions.
        for ([_][]const u8{ "languages", "grammars", "themes", "iconThemes", "productIconThemes", "snippets", "configuration", "configurationDefaults" }) |key| {
            if (contributes.object.contains(key)) return true;
        }
        return false;
    }

    pub fn getRuntimeState(self: *const RuntimeInventory, identifier: []const u8, desired: []const *const scanner.ScannedExtension) ?Action {
        var running: ?Entry = null;
        var next: ?*const scanner.ScannedExtension = null;
        for (self.entries) |entry| if (util.areSameExtensions(entry.identifier, identifier)) {
            running = entry;
            break;
        };
        for (desired) |entry| if (util.areSameExtensions(entry.identifier, identifier)) {
            next = entry;
            break;
        };
        if (running) |entry| {
            if (next) |description| {
                if (std.mem.eql(u8, entry.version, description.version) and std.mem.eql(u8, entry.location, description.location)) return null;
            }
            if (entry.declarative) return .ReloadWindow;
        } else if (next == null) return null;
        if (next) |description| if (hasWindowContributions(description.*)) return .ReloadWindow;
        return .RestartExtensions;
    }

    pub fn hasChanges(self: *const RuntimeInventory, desired: []const *const scanner.ScannedExtension) bool {
        for (self.entries) |entry| if (self.getRuntimeState(entry.identifier, desired) != null) return true;
        for (desired) |entry| if (self.getRuntimeState(entry.identifier, desired) != null) return true;
        return false;
    }

    pub fn requiresReload(self: *const RuntimeInventory, desired: []const *const scanner.ScannedExtension) bool {
        for (self.entries) |entry| if (self.getRuntimeState(entry.identifier, desired) == .ReloadWindow) return true;
        for (desired) |entry| if (self.getRuntimeState(entry.identifier, desired) == .ReloadWindow) return true;
        return false;
    }
};

test "RuntimeInventory: distinguishes host-only changes from mounted extension points" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "code", .default_dir);
    try tmp.dir.createDir(io, "theme", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "code/package.json", .data = "{\"name\":\"code\",\"publisher\":\"pub\",\"version\":\"1.0.0\",\"engines\":{\"vscode\":\"*\"},\"main\":\"./main.js\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "theme/package.json", .data = "{\"name\":\"theme\",\"publisher\":\"pub\",\"version\":\"1.0.0\",\"engines\":{\"vscode\":\"*\"},\"contributes\":{\"themes\":[]}}" });
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var inventory = try scanner.scanAllExtensions(allocator, io, null, path[0..len]);
    defer inventory.deinit(allocator);
    const code = inventory.find("pub.code") orelse return error.TestUnexpectedResult;
    const theme = inventory.find("pub.theme") orelse return error.TestUnexpectedResult;
    var runtime = try RuntimeInventory.init(allocator, inventory.all);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(?RuntimeInventory.Action, null), runtime.getRuntimeState("pub.code", inventory.all));
    try std.testing.expectEqual(RuntimeInventory.Action.RestartExtensions, runtime.getRuntimeState("pub.code", &.{theme}).?);
    try std.testing.expectEqual(RuntimeInventory.Action.ReloadWindow, runtime.getRuntimeState("pub.theme", &.{code}).?);
    try std.testing.expect(!runtime.requiresReload(&.{theme}));
    try std.testing.expect(runtime.requiresReload(&.{code}));
}

/// Registry delta planned before sending IExtensionDescriptionDelta to the
/// local host. Existing descriptions retain their allocations so contributed
/// command metadata and other borrowed strings remain valid across a delta.
/// Activated extensions cannot be removed. The terminal does not yet have
/// dynamic registration/removal for every extension point; changes involving
/// those points return RequiresRestart rather than silently leaving stale UI.
pub const DescriptionDelta = struct {
    allocator: Allocator,
    next: []manager.ExtensionDescription,
    new_to_old: []?usize,
    old_retained: []bool,
    added: []const *const manager.ExtensionDescription,
    removed: []const []const u8,

    fn version(description: manager.ExtensionDescription) []const u8 {
        if (description.manifest != .object) return "";
        const value = description.manifest.object.get("version") orelse return "";
        return if (value == .string) value.string else "";
    }

    fn equivalent(left: manager.ExtensionDescription, right: manager.ExtensionDescription) bool {
        return std.ascii.eqlIgnoreCase(left.identifier, right.identifier) and std.mem.eql(u8, left.path, right.path) and std.mem.eql(u8, version(left), version(right));
    }

    fn supportsDelta(description: manager.ExtensionDescription) bool {
        if (std.ascii.eqlIgnoreCase(description.identifier, "vscode.terminal-suggest")) return false;
        if (description.manifest == .object) if (description.manifest.object.get("contributes")) |contributes| {
            if (contributes == .object) {
                for (contributes.object.keys()) |key| {
                    // Commands are registered through MainThreadCommands and
                    // become visible when the extension activates. Other
                    // extension points still need a registry-delta port.
                    if (!std.mem.eql(u8, key, "commands") and !std.mem.eql(u8, key, "menus")) return false;
                }
            }
        };
        for (description.activation_events) |event| if (std.mem.startsWith(u8, event, "workspaceContains")) return false;
        return true;
    }

    pub fn plan(allocator: Allocator, io: Io, current: []const manager.ExtensionDescription, paths: []const ExtensionPath, activation_started: *const std.StringHashMapUnmanaged(void)) !DescriptionDelta {
        const next = if (paths.len == 0) try allocator.alloc(manager.ExtensionDescription, 0) else try readExtensions(allocator, io, paths);
        errdefer {
            for (next) |*description| description.deinit(allocator);
            allocator.free(next);
        }
        const mapping = try allocator.alloc(?usize, next.len);
        errdefer allocator.free(mapping);
        @memset(mapping, null);
        const retained = try allocator.alloc(bool, current.len);
        errdefer allocator.free(retained);
        @memset(retained, false);
        var add: std.ArrayList(*const manager.ExtensionDescription) = .empty;
        errdefer add.deinit(allocator);
        var remove: std.ArrayList([]const u8) = .empty;
        errdefer remove.deinit(allocator);
        for (next, 0..) |*candidate, i| {
            for (current, 0..) |old, index| {
                if (!equivalent(old, candidate.*)) continue;
                retained[index] = true;
                mapping[i] = index;
                break;
            } else {
                if (!supportsDelta(candidate.*)) return error.RequiresRestart;
                try add.append(allocator, candidate);
            }
        }
        for (current, 0..) |description, i| {
            if (retained[i]) continue;
            if (!supportsDelta(description)) return error.RequiresRestart;
            var iterator = activation_started.keyIterator();
            while (iterator.next()) |id| if (std.ascii.eqlIgnoreCase(id.*, description.identifier)) return error.RequiresRestart;
            try remove.append(allocator, description.identifier);
        }
        const added = try add.toOwnedSlice(allocator);
        errdefer allocator.free(added);
        return .{ .allocator = allocator, .next = next, .new_to_old = mapping, .old_retained = retained, .added = added, .removed = try remove.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *DescriptionDelta) void {
        for (self.next) |*description| description.deinit(self.allocator);
        self.allocator.free(self.next);
        self.allocator.free(self.new_to_old);
        self.allocator.free(self.old_retained);
        self.allocator.free(self.added);
        self.allocator.free(self.removed);
    }

    /// Commit only after the host has acknowledged the registry delta.
    pub fn commit(self: *DescriptionDelta, current: []manager.ExtensionDescription) []manager.ExtensionDescription {
        for (self.next, self.new_to_old) |*candidate, previous| if (previous) |index| {
            candidate.deinit(self.allocator);
            candidate.* = current[index];
        };
        for (current, self.old_retained) |*description, retained| if (!retained) description.deinit(self.allocator);
        self.allocator.free(current);
        const result = self.next;
        self.next = &.{};
        return result;
    }
};

test "DescriptionDelta: keeps unchanged manifests and rejects activated removals" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "old", .default_dir);
    try tmp.dir.createDir(io, "new", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "old/package.json", .data = "{\"name\":\"old\",\"publisher\":\"pub\",\"version\":\"1.0.0\",\"main\":\"./main.js\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "new/package.json", .data = "{\"name\":\"new\",\"publisher\":\"pub\",\"version\":\"1.0.0\",\"main\":\"./main.js\",\"activationEvents\":[\"onLanguage:zig\"]}" });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const old_path = try std.fs.path.join(allocator, &.{ buffer[0..len], "old" });
    defer allocator.free(old_path);
    const new_path = try std.fs.path.join(allocator, &.{ buffer[0..len], "new" });
    defer allocator.free(new_path);
    var current = try readExtensions(allocator, io, &.{.{ .path = old_path }});
    defer {
        for (current) |*description| description.deinit(allocator);
        allocator.free(current);
    }
    const original_manifest = current[0].identifier.ptr;
    var activated: std.StringHashMapUnmanaged(void) = .empty;
    defer activated.deinit(allocator);
    try activated.put(allocator, "pub.old", {});
    try std.testing.expectError(error.RequiresRestart, DescriptionDelta.plan(allocator, io, current, &.{.{ .path = new_path }}, &activated));
    var delta = try DescriptionDelta.plan(allocator, io, current, &.{ .{ .path = old_path }, .{ .path = new_path } }, &activated);
    defer delta.deinit();
    try std.testing.expectEqual(@as(usize, 1), delta.added.len);
    try std.testing.expectEqual(@as(usize, 0), delta.removed.len);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const payload = try manager.buildExtensionsDelta(arena.allocator(), 2, delta.removed, delta.added);
    try std.testing.expectEqual(@as(i64, 2), payload.object.get("versionId").?.integer);
    const added = payload.object.get("toAdd").?.array.items[0];
    try std.testing.expectEqualStrings("pub.new", added.object.get("identifier").?.object.get("value").?.string);
    try std.testing.expectEqualStrings("onLanguage:zig", payload.object.get("addActivationEvents").?.object.get("pub.new").?.array.items[0].string);
    current = delta.commit(current);
    try std.testing.expect(current[0].identifier.ptr == original_manifest);
    try std.testing.expectEqual(@as(usize, 2), current.len);
}
