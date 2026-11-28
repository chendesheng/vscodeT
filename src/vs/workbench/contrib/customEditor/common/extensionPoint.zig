// Port of CustomEditorsDataRenderer in
// `src/vs/workbench/contrib/customEditor/common/extensionPoint.ts`.
// The manifest table is descriptive; custom-editor webviews are separate.
const std = @import("std");
const features = @import("../../../services/extensionManagement/common/extensionFeatures.zig");

fn shouldRender(manifest: std.json.Value) bool {
    return features.contribution(manifest, "customEditors") != .null;
}
fn renderPriority(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (value == .string) return value.string;
    var entries: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "textEditor", "diffEditor" }) |key| {
        const priority = features.asString(features.property(value, key));
        if (priority.len > 0) try entries.append(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ key, priority }));
    }
    return std.mem.join(allocator, ", ", entries.items);
}
fn render(allocator: std.mem.Allocator, manifest: std.json.Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const entries = features.items(features.contribution(manifest, "customEditors"));
    if (entries.len == 0) return allocator.dupe(u8, "");
    var table: features.Table = .{ .allocator = scratch, .headers = &.{ "View Type", "Priority", "Filename Pattern" } };
    for (entries) |entry| {
        var patterns: std.ArrayList([]const u8) = .empty;
        for (features.items(features.property(entry, "selector"))) |selector| {
            const pattern = features.asString(features.property(selector, "filenamePattern"));
            if (pattern.len > 0) try patterns.append(scratch, pattern);
        }
        try table.append(&.{ features.asString(features.property(entry, "viewType")), try renderPriority(scratch, features.property(entry, "priority")), try std.mem.join(scratch, ", ", patterns.items) });
    }
    return table.markdown(allocator);
}
pub const custom_editors_feature: features.Descriptor = .{ .id = "customEditors", .label = "Custom Editors", .should_render = shouldRender, .render = render };
