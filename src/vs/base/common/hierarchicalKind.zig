// Port of `src/vs/base/common/hierarchicalKind.ts`.
const std = @import("std");

pub const HierarchicalKind = struct {
    value: []const u8,

    pub const sep = '.';
    pub const None = HierarchicalKind{ .value = "@@none@@" };
    pub const Empty = HierarchicalKind{ .value = "" };

    pub fn init(value: []const u8) HierarchicalKind {
        return .{ .value = value };
    }

    pub fn equals(self: HierarchicalKind, other: HierarchicalKind) bool {
        return std.mem.eql(u8, self.value, other.value);
    }

    pub fn contains(self: HierarchicalKind, other: HierarchicalKind) bool {
        return self.equals(other) or self.value.len == 0 or
            (other.value.len > self.value.len and std.mem.startsWith(u8, other.value, self.value) and other.value[self.value.len] == sep);
    }

    pub fn intersects(self: HierarchicalKind, other: HierarchicalKind) bool {
        return self.contains(other) or other.contains(self);
    }

    /// Returns a kind whose string is owned by the caller.
    pub fn append(self: HierarchicalKind, allocator: std.mem.Allocator, parts: []const []const u8) !HierarchicalKind {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        if (self.value.len != 0) try result.appendSlice(allocator, self.value);
        for (parts, 0..) |part, index| {
            if (self.value.len != 0 or index != 0) try result.append(allocator, sep);
            try result.appendSlice(allocator, part);
        }
        return .init(try result.toOwnedSlice(allocator));
    }
};

test "HierarchicalKind: dot-separated containment and intersection" {
    const a = std.testing.allocator;
    const base = HierarchicalKind.init("source");
    const child = try base.append(a, &.{ "organizeImports", "custom" });
    defer a.free(child.value);
    try std.testing.expectEqualStrings("source.organizeImports.custom", child.value);
    try std.testing.expect(base.contains(child));
    try std.testing.expect(!child.contains(base));
    try std.testing.expect(!base.contains(.init("sourceOther")));
    try std.testing.expect(base.intersects(child) and child.intersects(base));
    try std.testing.expect(HierarchicalKind.Empty.contains(child));
    try std.testing.expect(!HierarchicalKind.None.contains(child));
}
