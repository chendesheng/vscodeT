// Port of the gallery query/response contract tested by
// `src/vs/platform/extensionManagement/test/common/extensionGalleryService.test.ts`.
const std = @import("std");
const gallery = @import("../../common/extensionGalleryService.zig");

test "ExtensionGalleryService: encodes search and VS Code target filters" {
    const allocator = std.testing.allocator;
    const raw = try (gallery.Query{ .criteria = &.{.{ .filterType = @backingInt(gallery.FilterType.search_text), .value = "theme" }}, .sort_by = .installs }).encode(allocator);
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Microsoft.VisualStudio.Code") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"sortBy\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"value\":\"theme\"") != null);
}

test "ExtensionGalleryService: owns result strings and preserves assets and statistics" {
    const allocator = std.testing.allocator;
    var page = try gallery.Page.parse(allocator,
        \\{"results":[{"extensions":[{"extensionName":"example","publisher":{"publisherName":"pub"},"displayName":"Example","versions":[{"version":"1.0.0","files":[{"assetType":"Microsoft.VisualStudio.Services.Content.Details","source":"https://example.test/readme"}]}],"statistics":[{"statisticName":"install","value":123}]}],"resultMetadata":[{"metadataType":"ResultCount","metadataItems":[{"name":"TotalCount","count":17}]}]}]}
    );
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 17), page.total);
    try std.testing.expectEqualStrings("Example", page.extensions[0].displayName.?);
    try std.testing.expectEqual(@as(f64, 123), page.extensions[0].statistic("install").?);
    try std.testing.expectEqualStrings("https://example.test/readme", page.extensions[0].versions[0].asset("Microsoft.VisualStudio.Services.Content.Details").?);
}

test "ExtensionGalleryService: selects compatible release or explicitly requested prerelease" {
    const asset = gallery.Asset{ .assetType = "Microsoft.VisualStudio.Services.VSIXPackage", .source = "https://example.test/package" };
    const prerelease = gallery.Property{ .key = "Microsoft.VisualStudio.Code.PreRelease", .value = "true" };
    const incompatible = gallery.Property{ .key = "Microsoft.VisualStudio.Code.Engine", .value = "^10.0.0" };
    const entry = gallery.GalleryExtension{ .extensionName = "extension", .publisher = .{ .publisherName = "pub" }, .versions = &.{
        .{ .version = "3.0.0", .files = &.{asset}, .properties = &.{incompatible} },
        .{ .version = "2.0.0", .files = &.{asset}, .properties = &.{prerelease} },
        .{ .version = "1.0.0", .files = &.{asset} },
    } };
    try std.testing.expectEqualStrings("1.0.0", entry.selectVersion(null, false).?.version);
    try std.testing.expectEqualStrings("2.0.0", entry.selectVersion(null, true).?.version);
    try std.testing.expectEqualStrings("2.0.0", entry.selectVersion("2.0.0", false).?.version);
    try std.testing.expect(entry.selectVersion("3.0.0", true) == null);
}
