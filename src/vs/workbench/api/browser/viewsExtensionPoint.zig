// Port of ViewContainersDataRenderer and ViewsDataRenderer in
// `src/vs/workbench/api/browser/viewsExtensionPoint.ts`.
// This describes contributed views; mounting arbitrary contributed views
// remains a separate extension-point lifecycle.
const std = @import("std");
const features = @import("../../services/extensionManagement/common/extensionFeatures.zig");

fn groupedFeature(comptime id: []const u8, comptime label: []const u8, comptime name_key: []const u8, comptime name_label: []const u8) features.Descriptor {
    const Renderer = struct {
        fn shouldRender(manifest: std.json.Value) bool {
            return features.contribution(manifest, id) != .null;
        }
        fn render(allocator: std.mem.Allocator, manifest: std.json.Value) ![]u8 {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const scratch = arena.allocator();
            const groups = features.contribution(manifest, id);
            if (groups != .object) return allocator.dupe(u8, "");
            var table: features.Table = .{ .allocator = scratch, .headers = &.{ "ID", name_label, "Where" } };
            var iterator = groups.object.iterator();
            while (iterator.next()) |group| for (features.items(group.value_ptr.*)) |entry| {
                try table.append(&.{ features.asString(features.property(entry, "id")), features.asString(features.property(entry, name_key)), group.key_ptr.* });
            };
            if (table.rows.items.len == 0) return allocator.dupe(u8, "");
            table.sort();
            return table.markdown(allocator);
        }
    };
    return .{ .id = id, .label = label, .should_render = Renderer.shouldRender, .render = Renderer.render };
}

pub const containers_feature = groupedFeature("viewsContainers", "View Containers", "title", "Title");
pub const views_feature = groupedFeature("views", "Views", "name", "Name");
