// Port of the user-extension location scan from
// `src/vs/platform/extensionManagement/common/extensionsScannerService.ts`
// (`ExtensionsScanner.scanExtensionsFromLocation`, `scanExtension` and
// `scanExtensionManifest`).
//
// The TUI has no user-data profiles, so it performs the location scan that
// upstream's `scanAllUserExtensions` uses instead of the profile
// (`extensions.json`) scan. NLS translation, manifest validation, the
// metadata cache and `applyScanOptions` (invalid filtering and latest-version
// picking) are not ported; every directory with a readable JSON-object
// manifest is returned, sorted by location like upstream.
const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("extensionManagementUtil.zig");

pub const ExtensionType = enum { system, user };

pub const ScannedExtension = struct {
    location: []u8,
    /// `getGalleryExtensionId(publisher, name)`, i.e. the lowercased id.
    identifier: []u8,
    manifest: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *ScannedExtension, allocator: Allocator) void {
        allocator.free(self.location);
        allocator.free(self.identifier);
        self.manifest.deinit();
    }
};

/// Scans the direct child directories of `location` for extension manifests,
/// skipping dot-directories for user extensions. A missing directory scans as
/// empty, matching a fresh VS Code install that has never added an extension.
pub fn scanExtensionsFromLocation(
    allocator: Allocator,
    io: std.Io,
    location: []const u8,
    extension_type: ExtensionType,
) ![]ScannedExtension {
    var dir = std.Io.Dir.cwd().openDir(io, location, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(ScannedExtension, 0),
        else => return err,
    };
    defer dir.close(io);

    var extensions: std.array_list.Managed(ScannedExtension) = .init(allocator);
    errdefer {
        for (extensions.items) |*extension| extension.deinit(allocator);
        extensions.deinit();
    }

    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        // Do not consider user extension folders starting with `.`.
        if (extension_type == .user and entry.name.len > 0 and entry.name[0] == '.') continue;
        // Follow symlinks like `IFileService.resolve` does: linked extension
        // folders are supported by VS Code's scanner.
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (stat.kind != .directory) continue;

        const child = try std.fs.path.join(allocator, &.{ location, entry.name });
        defer allocator.free(child);
        var extension = (try scanExtension(allocator, io, child)) orelse continue;
        extensions.append(extension) catch |err| {
            extension.deinit(allocator);
            return err;
        };
    }

    // Make sure extensions are in the same order always, like upstream.
    std.mem.sort(ScannedExtension, extensions.items, {}, lessThanLocation);
    return extensions.toOwnedSlice();
}

pub fn findExtension(extensions: []const ScannedExtension, identifier: []const u8) ?*const ScannedExtension {
    for (extensions) |*extension| {
        if (util.areSameExtensions(extension.identifier, identifier)) return extension;
    }
    return null;
}

fn scanExtension(allocator: Allocator, io: std.Io, location: []const u8) !?ScannedExtension {
    const manifest_path = try std.fs.path.join(allocator, &.{ location, "package.json" });
    defer allocator.free(manifest_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited) catch return null;
    defer allocator.free(content);

    var manifest = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    var keep_manifest = false;
    defer if (!keep_manifest) manifest.deinit();

    const object = switch (manifest.value) {
        .object => |object| object,
        else => return null,
    };
    const name_value = object.get("name") orelse return null;
    const name = switch (name_value) {
        .string => |name| name,
        else => return null,
    };
    if (name.len == 0) return null;

    // Allow a missing publisher so the authoring experience stays smooth.
    const publisher = if (object.get("publisher")) |value| switch (value) {
        .string => |publisher| if (publisher.len > 0) publisher else util.undefined_publisher,
        else => util.undefined_publisher,
    } else util.undefined_publisher;

    const identifier = try util.getGalleryExtensionId(allocator, publisher, name);
    errdefer allocator.free(identifier);
    const owned_location = try allocator.dupe(u8, location);
    errdefer allocator.free(owned_location);

    keep_manifest = true;
    return .{
        .location = owned_location,
        .identifier = identifier,
        .manifest = manifest,
    };
}

fn lessThanLocation(_: void, a: ScannedExtension, b: ScannedExtension) bool {
    return std.mem.order(u8, a.location, b.location) == .lt;
}
