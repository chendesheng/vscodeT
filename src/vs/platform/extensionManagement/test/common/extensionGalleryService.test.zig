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
