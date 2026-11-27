// Port of the extension location scan from
// `src/vs/platform/extensionManagement/common/extensionsScannerService.ts`
// (`ExtensionsScanner.scanExtensionsFromLocation`, `scanExtension`,
// `scanExtensionManifest`, `scanAllExtensions`, `dedupExtensions` and the
// NLS subset of `extensionNls.ts`).
//
// The TUI has no user-data profiles, so it performs the location scan that
// upstream's `scanAllUserExtensions` uses instead of the profile
// (`extensions.json`) scan. The scanner owns the manifest metadata the
// Extensions view and the declarative registry consume: NLS-resolved
// displayName/description, the gallery identifier, the contributed categories
// and the parsed manifest.
//
// Terminal adaptations:
// - The manifest JSON is parsed after `stripJsonc`, matching the JSONC
//   tolerance of upstream's manifest parser.
// - Only the default `package.nls.json` is loaded; localized
//   `package.nls.<locale>.json` files and contribution-point localization are
//   not ported.
// - `engines.vscode` compatibility is checked for presence only (the semver
//   range check needs the product version and is not ported).
// - `ScanResult` keeps the raw system/user scans for inventory reporting and
//   the merged effective descriptions for contributions and host startup.
const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("extensionManagementUtil.zig");
const configuration_models = @import("../../configuration/common/configurationModels.zig");

pub const ExtensionType = enum { system, user };

pub const ScannedExtension = struct {
    location: []u8,
    /// `getGalleryExtensionId(publisher, name)`, i.e. the lowercased id.
    identifier: []u8,
    name: []u8,
    publisher: []u8,
    version: []u8,
    /// NLS-resolved manifest `displayName`, else the manifest `name`.
    display_name: []u8,
    /// NLS-resolved manifest `description`, else an empty string.
    description: []u8,
    categories: [][]u8,
    extension_type: ExtensionType,
    manifest: std.json.Parsed(std.json.Value),

    pub fn isBuiltin(self: ScannedExtension) bool {
        return self.extension_type == .system;
    }

    pub fn deinit(self: *ScannedExtension, allocator: Allocator) void {
        allocator.free(self.location);
        allocator.free(self.identifier);
        allocator.free(self.name);
        allocator.free(self.publisher);
        allocator.free(self.version);
        allocator.free(self.display_name);
        allocator.free(self.description);
        for (self.categories) |category| allocator.free(category);
        allocator.free(self.categories);
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
    var dir = std.Io.Dir.cwd().openDir(io, location, .{ .iterate = true }) catch {
        return allocator.alloc(ScannedExtension, 0);
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
        var extension = (try scanExtension(allocator, io, child, extension_type)) orelse continue;
        extensions.append(extension) catch |err| {
            extension.deinit(allocator);
            return err;
        };
    }

    // Make sure extensions are in the same order always, like upstream.
    std.mem.sort(ScannedExtension, extensions.items, {}, lessThanLocation);
    return extensions.toOwnedSlice();
}

/// Scans roots that are either one extension or a collection of extensions,
/// like the declarative registry's existing root handling. A root whose
/// `package.json` is not a valid extension manifest is treated as a directory
/// of extensions (`vscode/extensions/package.json` is such a collection
/// manifest). Missing roots are skipped.
pub fn scanExtensionsFromRoots(
    allocator: Allocator,
    io: std.Io,
    roots: []const []const u8,
    extension_type: ExtensionType,
) ![]ScannedExtension {
    var extensions: std.array_list.Managed(ScannedExtension) = .init(allocator);
    errdefer {
        for (extensions.items) |*extension| extension.deinit(allocator);
        extensions.deinit();
    }

    for (roots) |root| {
        const absolute = std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator) catch continue;
        defer allocator.free(absolute);
        if (try scanExtension(allocator, io, absolute, extension_type)) |extension| {
            extensions.append(extension) catch |err| {
                var owned = extension;
                owned.deinit(allocator);
                return err;
            };
            continue;
        }
        const children = try scanExtensionsFromLocation(allocator, io, absolute, extension_type);
        // Ownership of each scanned extension transfers to `extensions`; only
        // the slice that holds them is temporary.
        defer allocator.free(children);
        for (children, 0..) |extension, index| {
            extensions.append(extension) catch |err| {
                for (children[index..]) |*remaining| remaining.deinit(allocator);
                return err;
            };
        }
    }

    std.mem.sort(ScannedExtension, extensions.items, {}, lessThanLocation);
    return extensions.toOwnedSlice();
}

/// Port of `AbstractExtensionsScannerService.scanAllExtensions`: scans the
/// system (installed) and user locations and merges them by identifier.
/// `all` points into `system`/`user`; a user extension replaces the system
/// entry only when its version is strictly newer, matching upstream
/// `dedupExtensions` for the valid-manifest case.
pub const ScanResult = struct {
    system: []ScannedExtension,
    user: []ScannedExtension,
    all: []const *const ScannedExtension,

    pub fn deinit(self: *ScanResult, allocator: Allocator) void {
        for (self.system) |*extension| extension.deinit(allocator);
        allocator.free(self.system);
        for (self.user) |*extension| extension.deinit(allocator);
        allocator.free(self.user);
        allocator.free(self.all);
        self.* = undefined;
    }

    pub fn find(self: ScanResult, identifier: []const u8) ?*const ScannedExtension {
        for (self.all) |extension| {
            if (util.areSameExtensions(extension.identifier, identifier)) return extension;
        }
        return null;
    }
};

pub fn scanAllExtensions(
    allocator: Allocator,
    io: std.Io,
    system_location: ?[]const u8,
    user_location: ?[]const u8,
) !ScanResult {
    const system = if (system_location) |location|
        try scanExtensionsFromLocation(allocator, io, location, .system)
    else
        try allocator.alloc(ScannedExtension, 0);
    errdefer {
        for (system) |*extension| extension.deinit(allocator);
        allocator.free(system);
    }
    const user = if (user_location) |location|
        try scanExtensionsFromLocation(allocator, io, location, .user)
    else
        try allocator.alloc(ScannedExtension, 0);
    errdefer {
        for (user) |*extension| extension.deinit(allocator);
        allocator.free(user);
    }

    var merged: std.array_list.Managed(*const ScannedExtension) = .init(allocator);
    errdefer merged.deinit();
    try merged.ensureTotalCapacity(system.len + user.len);
    for (system) |*extension| merged.appendAssumeCapacity(extension);
    for (user) |*extension| {
        var existing_index: ?usize = null;
        for (merged.items, 0..) |existing, index| {
            if (!util.areSameExtensions(existing.identifier, extension.identifier)) continue;
            existing_index = index;
            break;
        }
        if (existing_index) |index| {
            // A user extension replaces the system entry only when it is a
            // newer version; equal versions keep the system entry.
            if (util.compareExtensionVersions(extension.version, merged.items[index].version) == .gt) {
                merged.items[index] = extension;
            }
        } else {
            merged.append(extension) catch |err| return err;
        }
    }

    return .{
        .system = system,
        .user = user,
        .all = try merged.toOwnedSlice(),
    };
}

pub fn findExtension(extensions: []const ScannedExtension, identifier: []const u8) ?*const ScannedExtension {
    for (extensions) |*extension| {
        if (util.areSameExtensions(extension.identifier, identifier)) return extension;
    }
    return null;
}

fn scanExtension(
    allocator: Allocator,
    io: std.Io,
    location: []const u8,
    extension_type: ExtensionType,
) !?ScannedExtension {
    const manifest_path = try std.fs.path.join(allocator, &.{ location, "package.json" });
    defer allocator.free(manifest_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited) catch return null;
    defer allocator.free(content);

    const sanitized = configuration_models.stripJsonc(allocator, content) catch return null;
    defer allocator.free(sanitized);
    var manifest = std.json.parseFromSlice(std.json.Value, allocator, sanitized, .{}) catch return null;
    var keep_manifest = false;
    defer if (!keep_manifest) manifest.deinit();

    const object = switch (manifest.value) {
        .object => |object| object,
        else => return null,
    };
    const name = stringField(object, "name") orelse return null;
    if (name.len == 0) return null;
    const version = stringField(object, "version") orelse return null;
    if (version.len == 0) return null;
    // Upstream's extension validator rejects a manifest without an engine
    // declaration. The range is not checked; see the file header.
    const engines = object.get("engines") orelse return null;
    if (engines != .object) return null;
    if (stringField(engines.object, "vscode") == null) return null;

    // Allow a missing publisher so the authoring experience stays smooth.
    const publisher = if (stringField(object, "publisher")) |publisher|
        if (publisher.len > 0) publisher else util.undefined_publisher
    else
        util.undefined_publisher;

    const identifier = try util.getGalleryExtensionId(allocator, publisher, name);
    errdefer allocator.free(identifier);
    const owned_location = try allocator.dupe(u8, location);
    errdefer allocator.free(owned_location);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_publisher = try allocator.dupe(u8, publisher);
    errdefer allocator.free(owned_publisher);
    const owned_version = try allocator.dupe(u8, version);
    errdefer allocator.free(owned_version);

    // Read the default NLS file only when a display string uses a key.
    var nls: ?std.json.Parsed(std.json.Value) = null;
    defer if (nls) |*parsed| parsed.deinit();
    const raw_display_name = stringField(object, "displayName");
    const raw_description = stringField(object, "description");
    if (usesNlsKey(raw_display_name) or usesNlsKey(raw_description)) {
        const nls_path = try std.fs.path.join(allocator, &.{ location, "package.nls.json" });
        defer allocator.free(nls_path);
        if (std.Io.Dir.cwd().readFileAlloc(io, nls_path, allocator, .unlimited)) |nls_text| {
            defer allocator.free(nls_text);
            nls = std.json.parseFromSlice(std.json.Value, allocator, nls_text, .{}) catch null;
        } else |_| {}
    }
    const nls_object = if (nls) |parsed| switch (parsed.value) {
        .object => |nls_values| nls_values,
        else => null,
    } else null;

    const display_name = try allocator.dupe(u8, resolveNls(nls_object, raw_display_name orelse name));
    errdefer allocator.free(display_name);
    const description = try allocator.dupe(u8, resolveNls(nls_object, raw_description orelse ""));
    errdefer allocator.free(description);

    var categories: std.array_list.Managed([]u8) = .init(allocator);
    errdefer {
        for (categories.items) |category| allocator.free(category);
        categories.deinit();
    }
    if (object.get("categories")) |items| {
        if (items == .array) for (items.array.items) |item| {
            if (item != .string) continue;
            const category = try allocator.dupe(u8, item.string);
            categories.append(category) catch |err| {
                allocator.free(category);
                return err;
            };
        };
    }

    keep_manifest = true;
    return .{
        .location = owned_location,
        .identifier = identifier,
        .name = owned_name,
        .publisher = owned_publisher,
        .version = owned_version,
        .display_name = display_name,
        .description = description,
        .categories = try categories.toOwnedSlice(),
        .extension_type = extension_type,
        .manifest = manifest,
    };
}

fn usesNlsKey(value: ?[]const u8) bool {
    const text = value orelse return false;
    return text.len > 2 and text[0] == '%' and text[text.len - 1] == '%';
}

fn resolveNls(nls: ?std.json.ObjectMap, raw: []const u8) []const u8 {
    if (!usesNlsKey(raw)) return raw;
    const map = nls orelse return raw;
    const key = raw[1 .. raw.len - 1];
    const value = map.get(key) orelse return raw;
    return switch (value) {
        .string => |text| text,
        else => raw,
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn lessThanLocation(_: void, a: ScannedExtension, b: ScannedExtension) bool {
    return std.mem.order(u8, a.location, b.location) == .lt;
}
