// Actionable extension notifications wait for a picker response. Escape and
// replacement of the picker resolve the RPC as dismissal.
const std = @import("std");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const QuickInputService = @import("../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const QuickPick = @import("../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const Item = @import("../../../platform/quickinput/common/quickInput.zig").QuickPickItem;

pub const Prompt = struct {
    allocator: std.mem.Allocator,
    quick_input: *QuickInputService,
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    items: []const Item,
    rpc: *rpc.RpcProtocol = undefined,
    request: u32 = 0,
    result: rpc.HandlerReply = .empty,

    pub fn show(allocator: std.mem.Allocator, quick_input: *QuickInputService, context: *anyopaque, show_status: *const fn (*anyopaque, []const u8) void, args: []const rpc.Arg) !rpc.HandlerReply {
        if (args.len < 4 or args[1] != .json or args[1].json != .string or args[3] != .json or args[3].json != .array) return error.InvalidNotification;
        const title = args[1].json.string;
        const detail = if (args[2] == .json and args[2].json == .object) args[2].json.object.get("detail") else null;
        const description = if (detail != null and detail.? == .string) detail.?.string else "";
        const commands = args[3].json.array.items;
        if (commands.len == 0) {
            show_status(context, title);
            return .empty;
        }
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var items: std.ArrayList(Item) = .empty;
        try items.append(a, .{ .item = .{ .id = "", .label = "Cancel" } });
        const instructions = try a.dupe(u8, description);
        for (commands) |command| {
            if (command != .object) continue;
            const label = command.object.get("title") orelse continue;
            const handle = command.object.get("handle") orelse continue;
            if (label != .string or handle != .integer) continue;
            try items.append(a, .{ .item = .{ .id = try std.fmt.allocPrint(a, "{d}", .{handle.integer}), .label = try a.dupe(u8, label.string), .description = instructions } });
        }
        const message = try a.dupe(u8, title);
        const self = try allocator.create(Prompt);
        self.* = .{ .allocator = allocator, .quick_input = quick_input, .arena = arena, .title = message, .items = items.items };
        return .{ .deferred = .{ .context = self, .start = start } };
    }

    fn start(context: *anyopaque, channel: *rpc.RpcProtocol, id: u32) void {
        const self: *Prompt = @ptrCast(@alignCast(context));
        self.rpc = channel;
        self.request = id;
        self.quick_input.showPick(self.items, .{ .placeholder = self.title, .cleanup = finish, .cleanup_context = self }, pick, self) catch finish(self);
    }

    fn pick(context: *anyopaque, picker: *QuickPick) !void {
        const self: *Prompt = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse return;
        const handle = std.fmt.parseInt(i64, item.id, 10) catch return;
        self.result = .{ .json = .{ .integer = handle } };
    }

    fn finish(context: *anyopaque) void {
        const self: *Prompt = @ptrCast(@alignCast(context));
        self.rpc.sendReply(self.request, self.result);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};
