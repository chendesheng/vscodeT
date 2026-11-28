// Port of the presentation rules in `src/vs/workbench/contrib/extensions/browser/extensionsWidgets.ts`.
// Terminal adaptation: compact install/rating labels, the pre-release bookmark
// and publisher verification marker use cell text rather than browser DOM.
const std = @import("std");
const model = @import("../common/extensions.zig");

pub const InstallCountWidget = struct {
    pub fn getInstallLabel(extension: model.IExtension, small: bool, buffer: []u8) ?[]const u8 {
        const count = extension.install_count orelse return null;
        if (!std.math.isFinite(count) or count <= 0) return null;
        if (small) {
            if (count > 1_000_000) {
                const millions = @floor(count / 100_000) / 10;
                return if (millions == @floor(millions)) std.fmt.bufPrint(buffer, "{d:.0}M", .{millions}) catch null else std.fmt.bufPrint(buffer, "{d:.1}M", .{millions}) catch null;
            }
            if (count > 1000) return std.fmt.bufPrint(buffer, "{d:.0}K", .{@floor(count / 1000)}) catch null;
        }
        return std.fmt.bufPrint(buffer, "{d:.0}", .{count}) catch null;
    }
};

pub const RatingsWidget = struct {
    pub fn getRatingLabel(extension: model.IExtension, small: bool, buffer: []u8) ?[]const u8 {
        const rating = extension.rating orelse return null;
        if (!std.math.isFinite(rating) or rating < 0 or rating > 5) return null;
        if (small and (extension.rating_count orelse 0) <= 0) return null;
        const rounded = @round(rating * 2) / 2;
        return if (rounded == @floor(rounded)) std.fmt.bufPrint(buffer, "★ {d:.0}", .{rounded}) catch null else std.fmt.bufPrint(buffer, "★ {d:.1}", .{rounded}) catch null;
    }
};

/// Port of PreReleaseBookmarkWidget: installed extensions show the bookmark
/// only when they opt into pre-release versions, while Marketplace entries
/// show it when a pre-release version is available.
pub const PreReleaseBookmarkWidget = struct {
    // Codicon.versions (extensions-pre-release).
    pub const glyph: u21 = 0xEB78;

    pub fn shouldShow(extension: model.IExtension) bool {
        return if (extension.state == .Installed) extension.is_pre_release else extension.has_pre_release;
    }
};

test "InstallCountWidget: truncates compact metrics like upstream" {
    var buffer: [32]u8 = undefined;
    var extension: model.IExtension = .{ .identifier = "pub.ext", .name = "ext", .display_name = "Ext", .description = "", .version = "1.0.0", .location = "", .publisher = "pub", .categories = &.{}, .is_builtin = false, .install_count = 1_299_999 };
    try std.testing.expectEqualStrings("1.2M", InstallCountWidget.getInstallLabel(extension, true, &buffer).?);
    extension.install_count = 1999;
    try std.testing.expectEqualStrings("1K", InstallCountWidget.getInstallLabel(extension, true, &buffer).?);
    extension.install_count = 1000;
    try std.testing.expectEqualStrings("1000", InstallCountWidget.getInstallLabel(extension, true, &buffer).?);
    extension.rating = 4.76;
    try std.testing.expect(RatingsWidget.getRatingLabel(extension, true, &buffer) == null);
    extension.rating_count = 10;
    try std.testing.expectEqualStrings("★ 5", RatingsWidget.getRatingLabel(extension, true, &buffer).?);
}
