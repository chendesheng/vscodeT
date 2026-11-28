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
    try std.testing.expectEqualStrings("2.0.0", entry.selectReleaseChannel(true).?.version);
    try std.testing.expectEqualStrings("1.0.0", entry.selectReleaseChannel(false).?.version);
}

test "ExtensionGalleryService: parses registry timestamps with fractions and offsets" {
    try std.testing.expectEqual(@as(?i64, 0), gallery.parseGalleryTimestamp("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 123), gallery.parseGalleryTimestamp("1970-01-01T02:00:00.123456+02:00"));
    try std.testing.expectEqual(@as(?i64, 951782400000), gallery.parseGalleryTimestamp("2000-02-29T00:00:00Z"));
    try std.testing.expect(gallery.parseGalleryTimestamp("2100-02-29T00:00:00Z") == null);
}

test "ExtensionGalleryService: normalizes native Open VSX exact-ID versions and assets" {
    const allocator = std.testing.allocator;
    var page = try gallery.parseOpenVsxExactPage(allocator, "VSCODE.emmet",
        \\{"offset":0,"totalSize":5,"extensions":[
        \\ {"namespace":"vscode","name":"emmet","version":"3.0.0","displayName":"Emmet","description":"Markup","namespaceDisplayName":"VS Code","categories":["Other"],"downloadCount":42,"targetPlatform":"universal","timestamp":"2024-12-10T11:10:00Z","engines":{"vscode":"^10.0.0"},"files":{"download":"https://open-vsx.org/download/3"}},
        \\ {"namespace":"vscode","name":"emmet","version":"2.0.0","preRelease":true,"engines":{"vscode":"^1.30.0"},"files":{"download":"https://open-vsx.org/download/2"}},
        \\ {"namespace":"vscode","name":"emmet","version":"1.95.3","engines":{"vscode":"^1.13.0"},"files":{"download":"https://open-vsx.org/download/1","manifest":"https://open-vsx.org/package.json","readme":"https://open-vsx.org/README.md","icon":"https://open-vsx.org/icon.png"}},
        \\ {"namespace":"another","name":"emmet","version":"99.0.0","engines":{"vscode":"*"},"files":{"download":"https://open-vsx.org/download/99"}},
        \\ {"namespace":"vscode","name":"emmet","version":"98.0.0","downloadable":false,"engines":{"vscode":"*"},"files":{"download":"https://open-vsx.org/download/98"}}]}
    );
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.extensions.len);
    const extension = page.extensions[0];
    try std.testing.expectEqualStrings("vscode", extension.publisher.publisherName);
    try std.testing.expectEqualStrings("Emmet", extension.displayName.?);
    try std.testing.expectEqual(@as(?f64, 42), extension.statistic("install"));
    try std.testing.expectEqual(@as(usize, 3), extension.versions.len);
    const stable = extension.selectVersion(null, false).?;
    try std.testing.expectEqualStrings("1.95.3", stable.version);
    try std.testing.expectEqualStrings("https://open-vsx.org/download/1", stable.asset("Microsoft.VisualStudio.Services.VSIXPackage").?);
    try std.testing.expectEqualStrings("https://open-vsx.org/package.json", stable.asset("Microsoft.VisualStudio.Code.Manifest").?);
    try std.testing.expectEqualStrings("https://open-vsx.org/README.md", stable.asset("Microsoft.VisualStudio.Services.Content.Details").?);
    try std.testing.expectEqualStrings("2.0.0", extension.selectVersion(null, true).?.version);
    try std.testing.expect(extension.selectVersion("3.0.0", true) == null);
}

test "ExtensionGalleryService: native Open VSX search preserves pagination and compatible versions" {
    const allocator = std.testing.allocator;
    var page = try gallery.parseOpenVsxSearchPage(allocator,
        \\{"offset":50,"totalSize":127,"extensions":[{"namespace":"vscode","name":"emmet","displayName":"Emmet","description":"Markup","downloadCount":42,"files":{"icon":"https://open-vsx.org/icon.png"},"allVersions":[
        \\ {"version":"3.0.0","targetPlatform":"universal","engines":{"vscode":"^10.0.0"},"files":{"download":"https://open-vsx.org/download/3"}},
        \\ {"version":"2.0.0-next.1","targetPlatform":"universal","engines":{"vscode":"^1.13.0"},"files":{"download":"https://open-vsx.org/download/2"}},
        \\ {"version":"1.95.3","targetPlatform":"universal","engines":{"vscode":"^1.13.0"},"files":{"download":"https://open-vsx.org/download/1"}}]}]}
    );
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 127), page.total);
    try std.testing.expectEqual(@as(usize, 1), page.extensions.len);
    const extension = page.extensions[0];
    try std.testing.expectEqualStrings("Emmet", extension.displayName.?);
    const version = extension.selectVersion(null, false).?;
    try std.testing.expectEqualStrings("1.95.3", version.version);
    try std.testing.expectEqualStrings("https://open-vsx.org/icon.png", version.asset("Microsoft.VisualStudio.Services.Icons.Default").?);
    try std.testing.expectEqualStrings("https://open-vsx.org/download/1", version.asset("Microsoft.VisualStudio.Services.VSIXPackage").?);
    try std.testing.expectEqualStrings("2.0.0-next.1", extension.selectVersion(null, true).?.version);
}
