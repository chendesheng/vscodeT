// Port of `src/vs/platform/notification/common/notificationMessage.ts`.
//
// Terminal adaptation: notification content is immutable and arena-owned
// (instead of frozen JS objects). The upstream type-level tests (nominal
// notification content and frozen-node checks) have no Zig runtime equivalent
// and are not ported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const linked = @import("../../../base/common/linkedText.zig");

pub const NotificationText = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: []const linked.LinkedTextNode,

    pub fn deinit(self: *NotificationText) void {
        self.arena.deinit();
    }

    pub fn getNodes(self: *const NotificationText) []const linked.LinkedTextNode {
        return self.nodes;
    }

    fn init(allocator: Allocator) NotificationText {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .nodes = &.{},
        };
    }

    pub fn link(allocator: Allocator, label: []const u8, href: []const u8, title: ?[]const u8) !NotificationText {
        var self = init(allocator);
        errdefer self.arena.deinit();
        const nodes = try self.arena.allocator().alloc(linked.LinkedTextNode, 1);
        nodes[0] = .{ .link = .{
            .label = try self.arena.allocator().dupe(u8, label),
            .href = try self.arena.allocator().dupe(u8, href),
            .title = if (title) |value| try self.arena.allocator().dupe(u8, value) else null,
        } };
        self.nodes = nodes;
        return self;
    }

    pub const Part = union(enum) {
        text: []const u8,
        content: *const NotificationText,
    };

    pub fn concat(allocator: Allocator, parts: []const Part) !NotificationText {
        var self = init(allocator);
        errdefer self.arena.deinit();
        var nodes = std.array_list.Managed(linked.LinkedTextNode).init(self.arena.allocator());
        for (parts) |part| {
            switch (part) {
                .text => |text| try nodes.append(.{ .text = try self.arena.allocator().dupe(u8, text) }),
                .content => |content| for (content.nodes) |node| {
                    try nodes.append(try cloneNode(self.arena.allocator(), node));
                },
            }
        }
        self.nodes = try nodes.toOwnedSlice();
        return self;
    }

    /// Substitutes literal strings and explicit links into a localized template
    /// without parsing markup.
    pub fn format(allocator: Allocator, template: []const u8, args: []const Part) !NotificationText {
        var self = init(allocator);
        errdefer self.arena.deinit();
        var nodes = std.array_list.Managed(linked.LinkedTextNode).init(self.arena.allocator());

        var index: usize = 0;
        var position: usize = 0;
        while (position < template.len) {
            if (template[position] == '{') {
                if (std.mem.indexOfScalarPos(u8, template, position, '}')) |end| {
                    const digits = template[position + 1 .. end];
                    if (digits.len > 0 and std.ascii.isDigit(digits[0])) {
                        const argument = std.fmt.parseInt(usize, digits, 10) catch null;
                        if (position > index) {
                            try nodes.append(.{ .text = try self.arena.allocator().dupe(u8, template[index..position]) });
                        }
                        if (argument != null and argument.? < args.len) {
                            switch (args[argument.?]) {
                                .text => |text| try nodes.append(.{ .text = try self.arena.allocator().dupe(u8, text) }),
                                .content => |content| for (content.nodes) |node| {
                                    try nodes.append(try cloneNode(self.arena.allocator(), node));
                                },
                            }
                        } else {
                            try nodes.append(.{ .text = try self.arena.allocator().dupe(u8, template[position .. end + 1]) });
                        }
                        index = end + 1;
                        position = index;
                        continue;
                    }
                }
            }
            position += 1;
        }
        if (index < template.len) {
            try nodes.append(.{ .text = try self.arena.allocator().dupe(u8, template[index..]) });
        }
        self.nodes = try nodes.toOwnedSlice();
        return self;
    }

    pub const Mapper = struct {
        context: *anyopaque,
        map: *const fn (context: *anyopaque, allocator: Allocator, text: []const u8) anyerror![]const u8,
    };

    /// Transforms displayed text without changing link targets.
    pub fn mapText(self: *const NotificationText, mapper: Mapper) !NotificationText {
        var result = init(self.allocator);
        errdefer result.arena.deinit();
        const allocator = result.arena.allocator();
        const nodes = try allocator.alloc(linked.LinkedTextNode, self.nodes.len);
        for (self.nodes, 0..) |node, index| {
            switch (node) {
                .text => |text| nodes[index] = .{ .text = try mapper.map(mapper.context, allocator, text) },
                .link => |link_node| nodes[index] = .{ .link = .{
                    .label = try mapper.map(mapper.context, allocator, link_node.label),
                    .href = try allocator.dupe(u8, link_node.href),
                    .title = if (link_node.title) |title| try allocator.dupe(u8, title) else null,
                } },
            }
        }
        result.nodes = nodes;
        return result;
    }

    pub fn toString(self: *const NotificationText, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        for (self.nodes) |node| {
            switch (node) {
                .text => |text| try out.writer.writeAll(text),
                .link => |link_node| try out.writer.writeAll(link_node.label),
            }
        }
        return out.toOwnedSlice();
    }
};

fn cloneNode(allocator: Allocator, node: linked.LinkedTextNode) !linked.LinkedTextNode {
    return switch (node) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .link => |link_node| .{ .link = .{
            .label = try allocator.dupe(u8, link_node.label),
            .href = try allocator.dupe(u8, link_node.href),
            .title = if (link_node.title) |title| try allocator.dupe(u8, title) else null,
        } },
    };
}
