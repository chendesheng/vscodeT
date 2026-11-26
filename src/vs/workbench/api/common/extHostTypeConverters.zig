// Port of the document-selector DTO conversion used by
// src/vs/workbench/api/common/extHostTypeConverters.ts.
// The received strings are owned by the supplied arena.
const std = @import("std");
const Allocator = std.mem.Allocator;
const selector_mod = @import("../../../editor/common/languageSelector.zig");
const std_uri = @import("../../../base/common/stdUri.zig");

pub fn parseSelector(arena: Allocator, value: std.json.Value) !selector_mod.Selector {
    switch (value) {
        .string => |language| return .{ .language = try arena.dupe(u8, language) },
        .array => |array| {
            const items = try arena.alloc(selector_mod.Selector, array.items.len);
            for (array.items, 0..) |item, index| items[index] = try parseSelector(arena, item);
            return .{ .list = items };
        },
        .object => |object| {
            var filter: selector_mod.Filter = .{};
            if (object.get("language")) |language| if (language == .string) {
                filter.language = try arena.dupe(u8, language.string);
            };
            if (object.get("scheme")) |scheme| if (scheme == .string) {
                filter.scheme = try arena.dupe(u8, scheme.string);
            };
            if (object.get("notebookType")) |notebook| if (notebook == .string) {
                filter.notebook_type = try arena.dupe(u8, notebook.string);
            };
            if (object.get("exclusive")) |exclusive| filter.exclusive = exclusive == .bool and exclusive.bool;
            if (object.get("isBuiltin")) |builtin| filter.is_builtin = builtin == .bool and builtin.bool;
            if (object.get("pattern")) |pattern_value| {
                if (pattern_value == .string) {
                    filter.pattern = .{ .string = try arena.dupe(u8, pattern_value.string) };
                } else if (pattern_value == .object) {
                    const text = if (pattern_value.object.get("pattern")) |pattern_text| if (pattern_text == .string) pattern_text.string else "" else "";
                    const base_value = pattern_value.object.get("baseUri");
                    const base = if (base_value) |base_json| blk: {
                        const components = std_uri.componentsFromJson(base_json, arena) catch break :blk "";
                        break :blk components.path;
                    } else "";
                    filter.pattern = .{ .relative = .{ .base = base, .pattern = try arena.dupe(u8, text) } };
                }
            }
            return .{ .filter = filter };
        },
        else => return .{ .language = "" },
    }
}
