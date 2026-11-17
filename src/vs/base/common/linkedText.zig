// Port of `src/vs/base/common/linkedText.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const regexp = @import("../../../support/regexp.zig");

pub const ILink = struct {
    label: []const u8,
    href: []const u8,
    title: ?[]const u8 = null,
};

pub const LinkedTextNode = union(enum) {
    text: []const u8,
    link: ILink,
};

pub const LinkedText = struct {
    nodes: []const LinkedTextNode,

    pub fn deinit(self: *LinkedText, allocator: Allocator) void {
        allocator.free(self.nodes);
    }

    pub fn toString(self: *const LinkedText, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        for (self.nodes) |node| {
            switch (node) {
                .text => |text| try out.writer.writeAll(text),
                .link => |link| try out.writer.writeAll(link.label),
            }
        }
        return out.toOwnedSlice();
    }
};

const link_pattern = "\\[([^\\]]+)\\]\\(((?:https?:\\/\\/|command:|file:)[^\\)\\s]+)(?: ([\"'])(.+?)(\\3))?\\)";

pub fn parseLinkedText(allocator: Allocator, text: []const u8) !LinkedText {
    var regex = try regexp.RegExp.init(link_pattern, .{ .ignore_case = true });
    defer regex.deinit();

    var nodes = std.array_list.Managed(LinkedTextNode).init(allocator);
    errdefer nodes.deinit();

    var index: usize = 0;
    var search_index: usize = 0;
    while (regex.searchFrom(text, search_index)) |result| {
        defer result.deinit();
        const start = result.index();
        if (start > index) try nodes.append(.{ .text = text[index..start] });
        const label = result.groupN(1);
        const href = result.groupN(2);
        const title = result.groupNOrNull(4);
        try nodes.append(.{ .link = .{ .label = label, .href = href, .title = title } });
        index = start + result.length();
        search_index = index;
    }
    if (index < text.len) try nodes.append(.{ .text = text[index..] });

    return .{ .nodes = try nodes.toOwnedSlice() };
}
