// Port of `src/vs/workbench/api/browser/mainThreadEditorTabs.ts`.
//
// Terminal adaptation: the adapter owns the tab list; this actor owns the tab
// model signature and emits `$acceptEditorTabModel` only when the list changes.
// Move/close operations are forwarded to the adapter.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const documents_and_editors = @import("mainThreadDocumentsAndEditors.zig");
const TabSpec = documents_and_editors.TabSpec;

pub const Host = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque, model: std.json.Value) anyerror!void,
    move_tab: *const fn (context: *anyopaque, tab_id: []const u8, index: usize) anyerror!void,
    close_tab: *const fn (context: *anyopaque, tab_id: []const u8) anyerror!bool,
    close_group: *const fn (context: *anyopaque, group_id: i64) anyerror!bool,
};

pub const MainThreadEditorTabs = struct {
    allocator: Allocator,
    host: Host,
    signature: u64 = 0,

    pub fn init(allocator: Allocator, host: Host) MainThreadEditorTabs {
        return .{ .allocator = allocator, .host = host };
    }

    pub fn deinit(self: *MainThreadEditorTabs) void {
        _ = self;
    }

    pub fn invoke(self: *MainThreadEditorTabs, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        _ = arena;
        if (std.mem.eql(u8, method, "$moveTab")) {
            if (args.len >= 2 and args[0] == .json and args[0].json == .string and args[1] == .json and args[1].json == .integer) {
                try self.host.move_tab(self.host.context, args[0].json.string, @intCast(args[1].json.integer));
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$closeTab")) {
            if (args.len > 0 and args[0] == .json and args[0].json == .array) {
                for (args[0].json.array.items) |value| {
                    if (value == .string) _ = self.host.close_tab(self.host.context, value.string) catch false;
                }
            }
            self.signature = 0;
            return .{ .json = .{ .bool = true } };
        }
        if (std.mem.eql(u8, method, "$closeGroup")) {
            if (args.len > 0 and args[0] == .json and args[0].json == .array) {
                for (args[0].json.array.items) |value| {
                    if (value == .integer) _ = self.host.close_group(self.host.context, value.integer) catch false;
                }
            }
            self.signature = 0;
            return .{ .json = .{ .bool = true } };
        }
        if (methodKind(method) == .request) {
            return .{ .err = .{ .name = "Unsupported", .message = method } };
        }
        return .empty;
    }

    /// Emits the model only when the active tab or the tab list changed.
    pub fn sync(self: *MainThreadEditorTabs, arena: Allocator, active_path: []const u8, tabs: []const TabSpec) !void {
        var signature: u64 = 0;
        for (tabs) |tab| {
            signature = signature *% 1099511628211;
            signature ^= std.hash.Wyhash.hash(0, tab.path);
            if (tab.is_dirty) signature ^= 0x9e3779b97f4a7c15;
            if (tab.is_active) signature ^= 0x517cc1b727220a95;
        }
        if (signature == self.signature) return;
        self.signature = signature;
        const model = try documents_and_editors.tabModel(arena, active_path, tabs);
        if (model == .null) return;
        try self.host.notify(self.host.context, model);
    }
};

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadEditorTabs.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

test "MainThreadEditorTabs: emits only when the tab model changes" {
    const allocator = std.testing.allocator;
    const Fake = struct {
        var notifications: usize = 0;
        fn notify(_: *anyopaque, _: std.json.Value) anyerror!void {
            notifications += 1;
        }
        fn move(_: *anyopaque, _: []const u8, _: usize) anyerror!void {}
        fn close(_: *anyopaque, _: []const u8) anyerror!bool {
            return true;
        }
        fn closeGroup(_: *anyopaque, _: i64) anyerror!bool {
            return true;
        }
    };
    var actor = MainThreadEditorTabs.init(allocator, .{
        .context = undefined,
        .notify = Fake.notify,
        .move_tab = Fake.move,
        .close_tab = Fake.close,
        .close_group = Fake.closeGroup,
    });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tabs = [_]TabSpec{.{ .path = "/a.ts", .label = "a.ts", .is_active = true, .is_dirty = false }};
    try actor.sync(arena.allocator(), "/a.ts", &tabs);
    try std.testing.expectEqual(@as(usize, 1), Fake.notifications);
    try actor.sync(arena.allocator(), "/a.ts", &tabs);
    try std.testing.expectEqual(@as(usize, 1), Fake.notifications);
}
