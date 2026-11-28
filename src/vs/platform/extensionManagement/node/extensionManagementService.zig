// Port of the local VSIX extraction/install boundary in
// `src/vs/platform/extensionManagement/node/extensionManagementService.ts`.
// The standalone terminal scanner reads the effective user directory directly;
// installation is staged in a hidden directory before publishing the version.
// Profile registration, signature services and dependency transactions are not
// yet ported. The caller owns the operation lifecycle and refresh event.
const std = @import("std");
const Allocator = std.mem.Allocator;
const gallery = @import("../common/extensionGalleryService.zig");
const util = @import("../common/extensionManagementUtil.zig");
const validator = @import("../../extensions/common/extensionValidator.zig");
const product = @import("../../product/common/product.zig");

const Manifest = struct {
    name: []const u8,
    publisher: []const u8,
    version: []const u8,
    engines: struct { vscode: []const u8 },
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

/// Extract an explicitly selected VSIX, validate package identity and engine,
/// and publish the extension atomically without replacing existing packages.
pub fn installVSIX(allocator: Allocator, io: std.Io, location: []const u8, bytes: []const u8, expected_identifier: ?[]const u8, expected_version: ?[]const u8) !void {
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
    const parsed = try std.json.parseFromSlice(Manifest, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const manifest = parsed.value;
    if (!validName(manifest.publisher) or !validName(manifest.name)) return error.InvalidExtensionIdentifier;
    _ = std.SemanticVersion.parse(manifest.version) catch return error.InvalidExtensionVersion;
    const identifier = try util.getGalleryExtensionId(allocator, manifest.publisher, manifest.name);
    defer allocator.free(identifier);
    if (expected_identifier) |expected| if (!std.ascii.eqlIgnoreCase(expected, identifier)) return error.ExtensionIdentifierMismatch;
    if (expected_version) |expected| if (!std.mem.eql(u8, expected, manifest.version)) return error.ExtensionVersionMismatch;
    if (!validator.isEngineValid(try std.SemanticVersion.parse(product.extension_engine_version), manifest.engines.vscode)) return error.IncompatibleExtension;
    // The upstream scanner stores install metadata in the installed manifest.
    // Preserve all manifest contributions and add the timestamp to the staged
    // copy only; the VSIX itself is never rewritten.
    const scanner = @import("../common/extensionsScannerService.zig");
    const previous = try scanner.scanExtensionsFromLocation(allocator, io, location, .user);
    defer {
        for (previous) |*extension| extension.deinit(allocator);
        allocator.free(previous);
    }
    var updated = false;
    for (previous) |extension| if (util.areSameExtensions(extension.identifier, identifier)) {
        updated = true;
        break;
    };
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
    const destination = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ identifier, manifest.version });
    defer allocator.free(destination);
    try stage.renamePreserve("extension", root, destination, io);
}

pub fn installFromGallery(allocator: Allocator, io: std.Io, location: []const u8, url: []const u8, identifier: []const u8, version: []const u8) !void {
    const bytes = try gallery.getAsset(allocator, io, url);
    defer allocator.free(bytes);
    try installVSIX(allocator, io, location, bytes, identifier, version);
}

/// Remove only user versions of an explicitly selected extension. Scanner
/// identities, not directory-name prefixes, determine which versions match.
pub fn uninstall(allocator: Allocator, io: std.Io, location: []const u8, identifier: []const u8) !void {
    const scanner = @import("../common/extensionsScannerService.zig");
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
