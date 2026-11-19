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

test "getGalleryExtensionId lowercases publisher and name" {
    const allocator = std.testing.allocator;
    const id = try getGalleryExtensionId(allocator, "VSCodeVim", "Vim");
    defer allocator.free(id);
    try std.testing.expectEqualStrings("vscodevim.vim", id);
}

test "getGalleryExtensionId defaults a missing publisher" {
    const allocator = std.testing.allocator;
    const id = try getGalleryExtensionId(allocator, null, "vim");
    defer allocator.free(id);
    try std.testing.expectEqualStrings("undefined_publisher.vim", id);
}

test "areSameExtensions ignores id case" {
    try std.testing.expect(areSameExtensions("vscodevim.vim", "VSCodeVim.Vim"));
    try std.testing.expect(!areSameExtensions("vscodevim.vim", "vscodevim.viml"));
}
