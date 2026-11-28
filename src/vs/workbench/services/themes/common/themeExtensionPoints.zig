// Port of ThemeDataRenderer in `src/vs/workbench/services/themes/common/themeExtensionPoints.ts`.
const std = @import("std");
const features = @import("../../extensionManagement/common/extensionFeatures.zig");
const groups = [_]struct { key: []const u8, label: []const u8 }{ .{ .key = "themes", .label = "Color Themes" }, .{ .key = "iconThemes", .label = "File Icon Themes" }, .{ .key = "productIconThemes", .label = "Product Icon Themes" } };
fn shouldRender(manifest: std.json.Value) bool {
    for (groups) |group| if (features.contribution(manifest, group.key) != .null) return true;
    return false;
}
fn render(allocator: std.mem.Allocator, manifest: std.json.Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    for (groups) |group| {
        const entries = features.items(features.contribution(manifest, group.key));
        if (entries.len == 0) continue;
        try output.writer.print("### {s}\n\n", .{group.label});
        for (entries) |entry| try output.writer.print("- {s}\n", .{features.asString(features.property(entry, "label"))});
        try output.writer.writeByte('\n');
    }
    return output.toOwnedSlice();
}
pub const themes_feature: features.Descriptor = .{ .id = "themes", .label = "Themes", .should_render = shouldRender, .render = render };
