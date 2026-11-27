// Port of `src/vs/workbench/api/browser/mainThreadOutputService.ts`.
const std = @import("std");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const output = @import("../../services/output/common/output.zig");
const OutputService = @import("../../contrib/output/browser/outputServices.zig").OutputService;
const OutputView = @import("../../contrib/output/browser/outputView.zig").OutputViewPane;
const IViewsService = @import("../../services/views/common/viewsService.zig").IViewsService;
const std_uri = @import("../../../base/common/stdUri.zig");
const Allocator = std.mem.Allocator;

pub const MainThreadOutputService = struct {
    allocator: Allocator,
    service: *OutputService,
    views: IViewsService,
    extension_id_pool: std.StringHashMap(u32),
    owned: std.ArrayList([]u8) = .empty,
    visible_listener: ?usize = null,
    host: Host,

    pub const Host = struct {
        context: *anyopaque,
        set_visible_channel: *const fn (*anyopaque, ?[]const u8) anyerror!void,
    };

    pub fn init(allocator: Allocator, service: *OutputService, views: IViewsService, host: Host) MainThreadOutputService {
        return .{ .allocator = allocator, .service = service, .views = views, .extension_id_pool = .init(allocator), .host = host };
    }

    pub fn attach(self: *MainThreadOutputService) !void {
        self.visible_listener = try self.service.on_visible_channel.listen(self, onVisibleChannel);
    }

    pub fn deinit(self: *MainThreadOutputService) void {
        if (self.visible_listener) |id| self.service.on_visible_channel.unlisten(id);
        for (self.owned.items) |id| {
            self.service.removeChannel(id);
            self.allocator.free(id);
        }
        self.owned.deinit(self.allocator);
        var keys = self.extension_id_pool.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.extension_id_pool.deinit();
    }

    fn onVisibleChannel(_: void, self: *MainThreadOutputService) !void {
        const visible = if (self.service.visible) self.service.active else null;
        try self.host.set_visible_channel(self.host.context, if (visible) |channel| channel.descriptor.id else null);
    }

    pub fn invoke(self: *MainThreadOutputService, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$register")) {
            const label = stringArg(args, 0) orelse return error.InvalidArguments;
            if (args.len < 4 or args[1] != .json) return error.InvalidArguments;
            const source = try std.Uri.parse(try std_uri.encodedResourceFromJson(arena, args[1].json));
            const extension = stringArg(args, 3) orelse return error.InvalidArguments;
            const entry = try self.extension_id_pool.getOrPut(extension);
            if (!entry.found_existing) {
                entry.key_ptr.* = self.allocator.dupe(u8, extension) catch |err| {
                    _ = self.extension_id_pool.remove(extension);
                    return err;
                };
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
            const id = try std.fmt.allocPrint(self.allocator, "extension-output-{s}-#{d}-{s}", .{ extension, entry.value_ptr.*, label });
            errdefer self.allocator.free(id);
            try self.owned.ensureUnusedCapacity(self.allocator, 1);
            _ = try self.service.registerChannel(.{ .id = id, .label = label, .source = source, .language_id = stringArg(args, 2), .extension_id = extension });
            self.owned.appendAssumeCapacity(id);
            return .{ .json = .{ .string = try arena.dupe(u8, id) } };
        }
        const id = stringArg(args, 0) orelse return error.InvalidArguments;
        if (std.mem.eql(u8, method, "$update")) {
            if (args.len < 2 or args[1] != .json or args[1].json != .integer) return error.InvalidArguments;
            const mode: output.OutputChannelUpdateMode = switch (args[1].json.integer) {
                1 => .Append,
                2 => .Replace,
                3 => .Clear,
                else => return error.InvalidArguments,
            };
            const till = if (args.len > 2 and args[2] == .json and args[2].json == .integer) std.math.cast(usize, args[2].json.integer) else null;
            if (mode == .Append or till != null) try self.service.update(id, mode, till);
        } else if (std.mem.eql(u8, method, "$reveal")) {
            if (try self.service.showChannel(id)) {
                const preserve = args.len > 1 and args[1] == .json and args[1].json == .bool and args[1].json.bool;
                _ = try self.views.openView(OutputView, !preserve);
            }
        } else if (std.mem.eql(u8, method, "$close")) {
            if (self.service.active) |channel| if (std.mem.eql(u8, channel.descriptor.id, id)) try self.views.closeView(OutputView.ID);
        } else if (std.mem.eql(u8, method, "$dispose")) {
            self.service.removeChannel(id);
            for (self.owned.items, 0..) |value, index| {
                if (!std.mem.eql(u8, value, id)) continue;
                self.allocator.free(self.owned.orderedRemove(index));
                break;
            }
        } else return .{ .err = .{ .name = "Unsupported", .message = method } };
        return .empty;
    }
};

fn stringArg(args: []const rpc.Arg, index: usize) ?[]const u8 {
    if (index >= args.len or args[index] != .json or args[index].json != .string) return null;
    return args[index].json.string;
}
