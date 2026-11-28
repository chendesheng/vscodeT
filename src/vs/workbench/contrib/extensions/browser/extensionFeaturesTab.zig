// Port of the manifest-contribution display in
// `src/vs/workbench/contrib/extensions/browser/extensionFeaturesTab.ts`.
// Terminal adaptation: the contribution tables are rendered as Markdown rows.
// Feature access telemetry and registered interactive feature renderers remain
// unported.
const std = @import("std");

pub fn property(value: std.json.Value, key: []const u8) std.json.Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}

fn string(value: std.json.Value) []const u8 {
    return if (value == .string) value.string else "";
}

pub fn render(allocator: std.mem.Allocator, manifest: std.json.Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    const contributes = property(manifest, "contributes");
    if (contributes != .object or contributes.object.count() == 0) {
        try writer.writeAll("No features contributed by this extension.");
        return output.toOwnedSlice();
    }
    var iterator = contributes.object.iterator();
    while (iterator.next()) |entry| {
        try writer.print("## {s}\n\n", .{entry.key_ptr.*});
        const value = entry.value_ptr.*;
        if (value == .array) {
            for (value.array.items) |item| {
                var label = string(item);
                if (label.len == 0) {
                    for ([_][]const u8{ "title", "label", "command", "id", "language", "name", "scopeName", "key" }) |key| {
                        label = string(property(item, key));
                        if (label.len != 0) break;
                    }
                }
                if (label.len != 0) try writer.print("- {s}\n", .{label});
            }
        } else if (value == .object) {
            const properties = property(value, "properties");
            var items = if (properties == .object) properties.object.iterator() else value.object.iterator();
            while (items.next()) |item| try writer.print("- `{s}`\n", .{item.key_ptr.*});
        }
        try writer.writeAll("\n");
    }
    return output.toOwnedSlice();
}
