// Port of the local VSIX extraction/install boundary in
// `src/vs/platform/extensionManagement/node/extensionManagementService.ts`.
// The standalone terminal scanner reads the effective user directory directly;
// installation is staged in a hidden directory before publishing the version.
// A staged transaction owns dependency/pack collection and rollback. Profile
// registration and signature services remain separate unported contracts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const gallery = @import("../common/extensionGalleryService.zig");
const util = @import("../common/extensionManagementUtil.zig");
const validator = @import("../../extensions/common/extensionValidator.zig");
const product = @import("../../product/common/product.zig");
const scanner = @import("../common/extensionsScannerService.zig");
const profiles = @import("../common/extensionsProfileScannerService.zig");

const Manifest = struct {
    name: []const u8,
    publisher: []const u8,
    version: []const u8,
    engines: struct { vscode: []const u8 },
    extensionDependencies: []const []const u8 = &.{},
    extensionPack: []const []const u8 = &.{},
};

fn validName(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

fn validArchivePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\:\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return parts.index == null;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.endsWith(u8, part, ".") or std.mem.endsWith(u8, part, " ")) return false;
        const stem = if (std.mem.indexOfScalar(u8, part, '.')) |i| part[0..i] else part;
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }) |reserved| if (std.ascii.eqlIgnoreCase(stem, reserved)) return false;
    }
    return true;
}

/// Package sources return owned bytes and the selected gallery version. The
/// injectable source also lets management tests remain independent of HTTP.
pub const Package = struct {
    bytes: []u8,
    version: []u8,

    pub fn deinit(self: Package, allocator: Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.version);
    }
};
pub const PackageSource = struct {
    context: *anyopaque,
    resolve: *const fn (*anyopaque, Allocator, std.Io, []const u8, bool) anyerror!?Package,
};

const Stage = struct { identifier: []const u8, version: []const u8, destination: []const u8, relative: []const u8, metadata: std.json.Value, reuse: bool = false };
const Transaction = struct {
    allocator: Allocator,
    io: std.Io,
    root: std.Io.Dir,
    stage: std.Io.Dir,
    location: []const u8,
    profile: *profiles.Profile,
    arena: std.heap.ArenaAllocator,
    inventory: scanner.ScanResult,
    source: ?PackageSource,
    prefer_prerelease: bool,
    pin_root: bool,
    packages: std.ArrayList(Stage) = .empty,

    fn contains(self: *const Transaction, id: []const u8) bool {
        for (self.packages.items) |package| if (util.areSameExtensions(package.identifier, id)) return true;
        return false;
    }

    fn collectDependency(self: *Transaction, id: []const u8, required: bool) anyerror!void {
        if (self.contains(id) or self.inventory.find(id) != null) return;
        const source = self.source orelse return; // local VSIX can install offline
        const package = (try source.resolve(source.context, self.allocator, self.io, id, self.prefer_prerelease)) orelse {
            if (required) return error.ExtensionDependencyUnavailable;
            return; // an unavailable/incompatible pack member is optional
        };
        defer package.deinit(self.allocator);
        try self.collect(package.bytes, id, package.version);
    }

    fn collect(self: *Transaction, bytes: []const u8, identifier: ?[]const u8, version: ?[]const u8) anyerror!void {
        const allocator = self.arena.allocator();
        const name = try std.fmt.allocPrint(allocator, "{d}", .{self.packages.items.len});
        try self.stage.createDir(self.io, name, .default_dir);
        var dir = try self.stage.openDir(self.io, name, .{});
        defer dir.close(self.io);
        const manifest = try extractPackage(self.allocator, self.io, dir, bytes, identifier, version);
        defer manifest.deinit();
        const id = try util.getGalleryExtensionId(allocator, manifest.value.publisher, manifest.value.name);
        if (self.contains(id)) return error.DuplicateExtensionPackage;
        const version_copy = try allocator.dupe(u8, manifest.value.version);
        var destination = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ id, version_copy });
        var reuse = false;
        for (self.inventory.user) |installed| {
            if (!util.areSameExtensions(installed.identifier, id) or !std.mem.eql(u8, installed.version, version_copy)) continue;
            // Reuse only the exact destination; platform-specific packages
            // with another directory name must not replace this package.
            if (!std.mem.eql(u8, std.fs.path.basename(installed.location), destination)) continue;
            destination = try allocator.dupe(u8, std.fs.path.basename(installed.location));
            reuse = true;
            break;
        }
        const relative = try std.fs.path.join(allocator, &.{ name, "extension" });
        var metadata: std.json.ObjectMap = .empty;
        try metadata.put(allocator, "installedTimestamp", .{ .integer = std.Io.Timestamp.now(self.io, .real).toMilliseconds() });
        try metadata.put(allocator, "updated", .{ .bool = self.inventory.find(id) != null });
        try metadata.put(allocator, "preRelease", .{ .bool = self.prefer_prerelease });
        try metadata.put(allocator, "pinned", .{ .bool = self.pin_root and self.packages.items.len == 0 });
        // Register before descending so cycles and diamonds are deduplicated.
        try self.packages.append(allocator, .{ .identifier = id, .version = version_copy, .destination = destination, .relative = relative, .metadata = .{ .object = metadata }, .reuse = reuse });
        try writeMetadata(self.allocator, self.io, dir, self.inventory.find(id) != null);
        for (manifest.value.extensionDependencies) |dependency| try self.collectDependency(dependency, true);
        for (manifest.value.extensionPack) |member| {
            if (self.inventory.find(id)) |old| {
                const previous = if (old.manifest.value == .object) old.manifest.value.object.get("extensionPack") orelse .null else .null;
                if (previous == .array) {
                    var found = false;
                    for (previous.array.items) |entry| if (entry == .string and util.areSameExtensions(entry.string, member)) {
                        found = true;
                        break;
                    };
                    if (found) continue; // only newly-added pack members on update
                }
            }
            try self.collectDependency(member, false);
        }
    }

    fn publish(self: *Transaction) !void {
        const allocator = self.arena.allocator();
        // Migrate a directory-only installation once, preserving the active
        // versions before adding any new selection to the default profile.
        if (!self.profile.exists) for (self.inventory.all) |extension| {
            if (extension.isBuiltin()) continue;
            const metadata = if (extension.manifest.value == .object) extension.manifest.value.object.get("__metadata") else null;
            try self.profile.select(extension.identifier, extension.version, extension.location, metadata);
        };
        for (self.packages.items) |package| {
            const path = try std.fs.path.join(allocator, &.{ self.location, package.destination });
            try self.profile.select(package.identifier, package.version, path, package.metadata);
        }
        // All manifests and dependencies are validated before touching the
        // visible inventory. Track only newly published packages for rollback.
        var published: std.ArrayList(Stage) = .empty;
        try published.ensureTotalCapacity(allocator, self.packages.items.len);
        errdefer for (published.items) |package| {
            self.root.renamePreserve(package.destination, self.stage, package.relative, self.io) catch {};
        };
        var index = self.packages.items.len;
        while (index > 0) {
            index -= 1;
            const package = self.packages.items[index];
            if (package.reuse) continue;
            try self.stage.renamePreserve(package.relative, self.root, package.destination, self.io);
            published.appendAssumeCapacity(package);
        }
        try self.profile.save(self.io);
    }
};

pub fn installVSIX(allocator: Allocator, io: std.Io, location: []const u8, bytes: []const u8, expected_identifier: ?[]const u8, expected_version: ?[]const u8) !void {
    return installWithSource(allocator, io, location, null, bytes, expected_identifier, expected_version, null, false);
}

/// Stage every package selected by the upstream dependency/pack traversal and
/// publish them together. Failed publication moves only transaction-created
/// versions back to staging; preexisting extension versions are untouched.
pub fn installWithSource(allocator: Allocator, io: std.Io, location: []const u8, system_location: ?[]const u8, bytes: []const u8, expected_identifier: ?[]const u8, expected_version: ?[]const u8, source: ?PackageSource, prefer_prerelease: bool) !void {
    return installWithOptions(allocator, io, location, system_location, bytes, expected_identifier, expected_version, source, prefer_prerelease, false);
}

fn installWithOptions(allocator: Allocator, io: std.Io, location: []const u8, system_location: ?[]const u8, bytes: []const u8, expected_identifier: ?[]const u8, expected_version: ?[]const u8, source: ?PackageSource, prefer_prerelease: bool, pin_root: bool) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, location);
    var root = try cwd.openDir(io, location, .{});
    defer root.close(io);
    var random: [16]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const stage_name = try std.fmt.allocPrint(allocator, ".minecode-install-{s}", .{hex[0..]});
    defer allocator.free(stage_name);
    try root.createDir(io, stage_name, .default_dir);
    defer root.deleteTree(io, stage_name) catch {};
    var stage = try root.openDir(io, stage_name, .{});
    defer stage.close(io);
    var inventory = try scanner.scanAllExtensions(allocator, io, system_location, location);
    defer inventory.deinit(allocator);
    const absolute = try cwd.realPathFileAlloc(io, location, allocator);
    defer allocator.free(absolute);
    var profile = try profiles.Profile.load(allocator, io, location);
    defer profile.deinit();
    var transaction: Transaction = .{ .allocator = allocator, .io = io, .root = root, .stage = stage, .location = absolute, .profile = &profile, .arena = .init(allocator), .inventory = inventory, .source = source, .prefer_prerelease = prefer_prerelease, .pin_root = pin_root };
    defer transaction.arena.deinit();
    try transaction.collect(bytes, expected_identifier, expected_version);
    try transaction.publish();
}

fn extractPackage(allocator: Allocator, io: std.Io, stage: std.Io.Dir, bytes: []const u8, expected_identifier: ?[]const u8, expected_version: ?[]const u8) !std.json.Parsed(Manifest) {
    try stage.writeFile(io, .{ .sub_path = "download.vsix", .data = bytes });
    var archive = try stage.openFile(io, "download.vsix", .{});
    defer archive.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = archive.reader(io, &buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var extracted: u64 = 0;
    while (try iterator.next()) |entry| {
        const filename = try entry.getFilename(&reader, &path_buf, .{});
        if (!validArchivePath(filename)) return error.InvalidVSIXPath;
        if (!std.mem.startsWith(u8, filename, "extension/")) continue;
        const relative = filename["extension/".len..];
        if (relative.len == 0) continue;
        if (std.mem.endsWith(u8, filename, "/")) {
            try stage.createDirPath(io, filename[0 .. filename.len - 1]);
            continue;
        }
        extracted = std.math.add(u64, extracted, entry.uncompressed_size) catch return error.VSIXTooLarge;
        if (extracted > 1024 * 1024 * 1024 or entry.uncompressed_size > 256 * 1024 * 1024) return error.VSIXTooLarge;
        const data = try allocator.alloc(u8, @intCast(entry.uncompressed_size));
        defer allocator.free(data);
        var writer: std.Io.Writer = .fixed(data);
        try entry.extractTo(&reader, &writer);
        if (writer.end != data.len or std.hash.Crc32.hash(data) != entry.crc32) return error.InvalidVSIXChecksum;
        const parent = std.fs.path.dirname(filename) orelse return error.InvalidVSIXPath;
        var directory = try stage.createDirPathOpen(io, parent, .{});
        defer directory.close(io);
        const file = try directory.createFile(io, std.fs.path.basename(filename), .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, data);
    }
    const raw = try stage.readFileAlloc(io, "extension/package.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(raw);
    const parsed = try std.json.parseFromSlice(Manifest, allocator, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer parsed.deinit();
    const manifest = parsed.value;
    if (!validName(manifest.publisher) or !validName(manifest.name)) return error.InvalidExtensionIdentifier;
    _ = std.SemanticVersion.parse(manifest.version) catch return error.InvalidExtensionVersion;
    const identifier = try util.getGalleryExtensionId(allocator, manifest.publisher, manifest.name);
    defer allocator.free(identifier);
    if (expected_identifier) |expected| if (!std.ascii.eqlIgnoreCase(expected, identifier)) return error.ExtensionIdentifierMismatch;
    if (expected_version) |expected| if (!std.mem.eql(u8, expected, manifest.version)) return error.ExtensionVersionMismatch;
    if (!validator.isEngineValid(try std.SemanticVersion.parse(product.extension_engine_version), manifest.engines.vscode)) return error.IncompatibleExtension;
    return parsed;
}

// Store upstream manifest install metadata only in the staged copy.
fn writeMetadata(allocator: Allocator, io: std.Io, stage: std.Io.Dir, updated: bool) !void {
    const raw = try stage.readFileAlloc(io, "extension/package.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(raw);
    var manifest_arena = std.heap.ArenaAllocator.init(allocator);
    defer manifest_arena.deinit();
    const scratch = manifest_arena.allocator();
    var manifest_json = try std.json.parseFromSliceLeaky(std.json.Value, scratch, raw, .{});
    if (manifest_json != .object) return error.InvalidExtensionManifest;
    var metadata = manifest_json.object.get("__metadata") orelse std.json.Value{ .object = .{} };
    if (metadata != .object) metadata = .{ .object = .{} };
    try metadata.object.put(scratch, "installedTimestamp", .{ .integer = std.Io.Timestamp.now(io, .real).toMilliseconds() });
    try metadata.object.put(scratch, "updated", .{ .bool = updated });
    try manifest_json.object.put(scratch, "__metadata", metadata);
    const installed_manifest = try std.json.Stringify.valueAlloc(scratch, manifest_json, .{ .whitespace = .indent_2 });
    try stage.writeFile(io, .{ .sub_path = "extension/package.json", .data = installed_manifest });
}

const GallerySource = struct {
    service_url: []const u8,

    fn resolve(context: *anyopaque, allocator: Allocator, io: std.Io, identifier: []const u8, prerelease: bool) !?Package {
        const self: *GallerySource = @ptrCast(@alignCast(context));
        const service: gallery.ExtensionGalleryService = .{ .allocator = allocator, .io = io, .service_url = self.service_url };
        var page = try service.getExtension(identifier);
        defer page.deinit();
        for (page.extensions) |entry| {
            const id = try util.getGalleryExtensionId(allocator, entry.publisher.publisherName, entry.extensionName);
            defer allocator.free(id);
            if (!util.areSameExtensions(id, identifier)) continue;
            const selected = entry.selectVersion(null, prerelease) orelse return null;
            const version = try allocator.dupe(u8, selected.version);
            errdefer allocator.free(version);
            const bytes = try gallery.getAsset(allocator, io, selected.asset("Microsoft.VisualStudio.Services.VSIXPackage").?);
            return .{ .bytes = bytes, .version = version };
        }
        return null;
    }
};

pub fn installFromGallery(allocator: Allocator, io: std.Io, location: []const u8, system_location: ?[]const u8, service_url: []const u8, url: []const u8, identifier: []const u8, version: []const u8, prerelease: bool, pinned: bool) !void {
    const bytes = try gallery.getAsset(allocator, io, url);
    defer allocator.free(bytes);
    var source: GallerySource = .{ .service_url = service_url };
    try installWithOptions(allocator, io, location, system_location, bytes, identifier, version, .{ .context = &source, .resolve = GallerySource.resolve }, prerelease, pinned);
}

/// Local installation through the workbench file-selection command. The
/// selected VSIX itself chooses the exact version; the gallery is optional
/// for resolving its dependency and pack manifests.
pub fn installVSIXFile(allocator: Allocator, io: std.Io, location: []const u8, system_location: ?[]const u8, service_url: []const u8, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024 * 1024));
    defer allocator.free(bytes);
    var source: GallerySource = .{ .service_url = service_url };
    try installWithOptions(allocator, io, location, system_location, bytes, null, null, if (service_url.len > 0) .{ .context = &source, .resolve = GallerySource.resolve } else null, false, true);
}

/// Remove only user versions of an explicitly selected extension. Scanner
/// identities, not directory-name prefixes, determine which versions match.
pub fn uninstall(allocator: Allocator, io: std.Io, location: []const u8, identifier: []const u8) !void {
    var profile = try profiles.Profile.load(allocator, io, location);
    defer profile.deinit();
    if (profile.exists) {
        // Other VS Code profiles can share these package directories. The
        // default profile's removal is logical; retain cached versions.
        profile.remove(identifier);
        try profile.save(io);
        return;
    }
    const extensions = try scanner.scanExtensionsFromLocation(allocator, io, location, .user);
    defer {
        for (extensions) |*extension| extension.deinit(allocator);
        allocator.free(extensions);
    }
    var root = try std.Io.Dir.cwd().openDir(io, location, .{});
    defer root.close(io);
    for (extensions) |extension| {
        if (!util.areSameExtensions(extension.identifier, identifier)) continue;
        const name = std.fs.path.basename(extension.location);
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidExtensionLocation;
        try root.deleteTree(io, name);
    }
}
