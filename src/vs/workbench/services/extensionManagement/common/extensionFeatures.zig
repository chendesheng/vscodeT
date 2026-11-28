// Port of `src/vs/workbench/services/extensionManagement/common/extensionFeatures.ts`.
// Feature registration and renderer selection are window-owned. The terminal
// projects table/Markdown renderer data into the shared Markdown document;
// access-consent telemetry and interactive browser elements are separate.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Descriptor = struct {
    id: []const u8,
    label: []const u8,
    should_render: *const fn (std.json.Value) bool,
    render: *const fn (Allocator, std.json.Value) anyerror![]u8,
};

pub const ExtensionFeaturesRegistry = struct {
    allocator: Allocator,
    features: std.ArrayList(Descriptor) = .empty,

    pub fn init(allocator: Allocator) ExtensionFeaturesRegistry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *ExtensionFeaturesRegistry) void {
        self.features.deinit(self.allocator);
    }
    pub fn registerExtensionFeature(self: *ExtensionFeaturesRegistry, descriptor: Descriptor) !void {
        if (self.getExtensionFeature(descriptor.id) != null) return error.ExtensionFeatureAlreadyRegistered;
        try self.features.append(self.allocator, descriptor);
    }
    pub fn getExtensionFeature(self: *const ExtensionFeaturesRegistry, id: []const u8) ?Descriptor {
        for (self.features.items) |feature| if (std.mem.eql(u8, feature.id, id)) return feature;
        return null;
    }
    pub fn getExtensionFeatures(self: *const ExtensionFeaturesRegistry) []const Descriptor {
        return self.features.items;
    }
};

pub fn property(value: std.json.Value, key: []const u8) std.json.Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
pub fn contribution(manifest: std.json.Value, key: []const u8) std.json.Value {
    return property(property(manifest, "contributes"), key);
}
pub fn asString(value: std.json.Value) []const u8 {
    if (value == .string) return value.string;
    const localized = property(value, "value");
    return if (localized == .string) localized.string else "";
}
pub fn items(value: std.json.Value) []const std.json.Value {
    return if (value == .array) value.array.items else &.{};
}
pub fn joinStrings(allocator: Allocator, value: std.json.Value) ![]const u8 {
    var strings: std.ArrayList([]const u8) = .empty;
    for (items(value)) |item| if (item == .string) try strings.append(allocator, item.string);
    return std.mem.join(allocator, ", ", strings.items);
}

/// Terminal rendering of the upstream ITableData contract. Each logical cell
/// is escaped and kept on one row by the shared Markdown table renderer.
pub const Table = struct {
    allocator: Allocator,
    rows: std.ArrayList([]const []const u8) = .empty,
    headers: []const []const u8,

    pub fn append(self: *Table, cells: []const []const u8) !void {
        if (cells.len != self.headers.len) return error.InvalidFeatureTable;
        try self.rows.append(self.allocator, try self.allocator.dupe([]const u8, cells));
    }

    fn lessThan(_: void, a: []const []const u8, b: []const []const u8) bool {
        return std.ascii.orderIgnoreCase(a[0], b[0]) == .lt;
    }
    pub fn sort(self: *Table) void {
        std.mem.sort([]const []const u8, self.rows.items, {}, lessThan);
    }
    pub fn markdown(self: *const Table, allocator: Allocator) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try writeRow(&output.writer, self.headers);
        try output.writer.writeByte('|');
        for (self.headers) |_| try output.writer.writeAll(" --- |");
        try output.writer.writeByte('\n');
        for (self.rows.items) |row| try writeRow(&output.writer, row);
        return output.toOwnedSlice();
    }
    fn writeRow(writer: *std.Io.Writer, row: []const []const u8) !void {
        try writer.writeByte('|');
        for (row) |cell| {
            try writer.writeByte(' ');
            for (cell) |ch| switch (ch) {
                '|', '\\' => {
                    try writer.writeByte('\\');
                    try writer.writeByte(ch);
                },
                '\r', '\n' => try writer.writeByte(' '),
                else => try writer.writeByte(ch),
            };
            try writer.writeAll(" |");
        }
        try writer.writeByte('\n');
    }
};
