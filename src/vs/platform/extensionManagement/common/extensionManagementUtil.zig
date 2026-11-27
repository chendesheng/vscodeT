// Port of the identifier helpers from
// `src/vs/platform/extensionManagement/common/extensionManagementUtil.ts`.
//
// The TUI has no gallery metadata, so the uuid half of `areSameExtensions` is
// not ported: extension identifiers are the id strings VS Code compares when
// no uuid is present.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// `UNDEFINED_PUBLISHER` from `src/vs/platform/extensions/common/extensions.ts`.
pub const undefined_publisher = "undefined_publisher";

pub fn getExtensionId(allocator: Allocator, publisher: []const u8, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ publisher, name });
}

pub fn adoptToGalleryExtensionId(allocator: Allocator, id: []const u8) Allocator.Error![]u8 {
    return std.ascii.allocLowerString(allocator, id);
}

pub fn getGalleryExtensionId(allocator: Allocator, publisher: ?[]const u8, name: []const u8) Allocator.Error![]u8 {
    const raw = try getExtensionId(allocator, publisher orelse undefined_publisher, name);
    defer allocator.free(raw);
    return adoptToGalleryExtensionId(allocator, raw);
}

/// The uuid-less branch of `areSameExtensions`: ids compare case-insensitively.
pub fn areSameExtensions(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Ordering subset of the npm `semver.gt`/`semver.eq` calls the scan merge
/// uses. Build metadata is ignored, numeric release segments compare
/// numerically and a release sorts after its prerelease. Prerelease
/// identifiers compare per semver (numeric before alphanumeric). A full semver
/// parser/range matcher is not ported; extension versions are normally plain
/// `major.minor.patch` strings.
pub fn compareExtensionVersions(a: []const u8, b: []const u8) std.math.Order {
    const left = splitVersion(a);
    const right = splitVersion(b);
    const release_order = compareRelease(left.release, right.release);
    if (release_order != .eq) return release_order;
    return comparePrerelease(left.prerelease, right.prerelease);
}

const VersionParts = struct { release: []const u8, prerelease: ?[]const u8 };

fn splitVersion(version: []const u8) VersionParts {
    const without_build = if (std.mem.indexOfScalar(u8, version, '+')) |index| version[0..index] else version;
    if (std.mem.indexOfScalar(u8, without_build, '-')) |index| {
        return .{ .release = without_build[0..index], .prerelease = without_build[index + 1 ..] };
    }
    return .{ .release = without_build, .prerelease = null };
}

fn compareRelease(a: []const u8, b: []const u8) std.math.Order {
    var left = std.mem.splitScalar(u8, a, '.');
    var right = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const left_part = left.next();
        const right_part = right.next();
        if (left_part == null and right_part == null) return .eq;
        const order = compareNumeric(left_part orelse "0", right_part orelse "0");
        if (order != .eq) return order;
    }
}

fn compareNumeric(a: []const u8, b: []const u8) std.math.Order {
    const left = std.fmt.parseInt(u64, a, 10) catch return std.mem.order(u8, a, b);
    const right = std.fmt.parseInt(u64, b, 10) catch return std.mem.order(u8, a, b);
    return std.math.order(left, right);
}

fn comparePrerelease(a: ?[]const u8, b: ?[]const u8) std.math.Order {
    if (a == null and b == null) return .eq;
    if (a == null) return .gt;
    if (b == null) return .lt;
    var left = std.mem.splitScalar(u8, a.?, '.');
    var right = std.mem.splitScalar(u8, b.?, '.');
    while (true) {
        const left_part = left.next();
        const right_part = right.next();
        if (left_part == null and right_part == null) return .eq;
        if (left_part == null) return .lt;
        if (right_part == null) return .gt;
        const left_numeric = std.fmt.parseInt(u64, left_part.?, 10) catch null;
        const right_numeric = std.fmt.parseInt(u64, right_part.?, 10) catch null;
        const order: std.math.Order = if (left_numeric == null and right_numeric == null)
            std.mem.order(u8, left_part.?, right_part.?)
        else if (left_numeric == null)
            .gt
        else if (right_numeric == null)
            .lt
        else
            std.math.order(left_numeric.?, right_numeric.?);
        if (order != .eq) return order;
    }
}

test "compareExtensionVersions orders release segments and prereleases" {
    try std.testing.expectEqual(std.math.Order.eq, compareExtensionVersions("1.0.0", "1.0.0"));
    try std.testing.expectEqual(std.math.Order.lt, compareExtensionVersions("1.0.0", "1.0.1"));
    try std.testing.expectEqual(std.math.Order.gt, compareExtensionVersions("1.10.0", "1.9.9"));
    try std.testing.expectEqual(std.math.Order.gt, compareExtensionVersions("2.0", "1.9.9"));
    try std.testing.expectEqual(std.math.Order.gt, compareExtensionVersions("1.0.0", "1.0.0-beta"));
    try std.testing.expectEqual(std.math.Order.lt, compareExtensionVersions("1.0.0-alpha", "1.0.0-beta"));
    try std.testing.expectEqual(std.math.Order.lt, compareExtensionVersions("1.0.0-2", "1.0.0-10"));
    try std.testing.expectEqual(std.math.Order.eq, compareExtensionVersions("1.0.0+build", "1.0.0"));
}

test "getGalleryExtensionId lowercases publisher and name" {
    const allocator = std.testing.allocator;
    const id = try getGalleryExtensionId(allocator, "Example", "Extension");
    defer allocator.free(id);
    try std.testing.expectEqualStrings("example.extension", id);
}

test "getGalleryExtensionId defaults a missing publisher" {
    const allocator = std.testing.allocator;
    const id = try getGalleryExtensionId(allocator, null, "vim");
    defer allocator.free(id);
    try std.testing.expectEqualStrings("undefined_publisher.vim", id);
}

test "areSameExtensions ignores id case" {
    try std.testing.expect(areSameExtensions("example.extension", "Example.Extension"));
    try std.testing.expect(!areSameExtensions("example.extension", "example.extension-other"));
}
