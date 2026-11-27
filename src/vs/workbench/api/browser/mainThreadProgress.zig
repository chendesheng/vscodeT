// Port of `src/vs/workbench/api/browser/mainThreadProgress.ts`.
const std = @import("std");
const progress = @import("../../../platform/progress/common/progress.zig");
const service_mod = @import("../../services/progress/browser/progressService.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const Allocator = std.mem.Allocator;

pub const MainThreadProgress = struct {
    allocator: Allocator,
    service: *service_mod.ProgressService,
    host: Host,
    entries: std.AutoHashMap(i64, *Entry),

    const Entry = struct {
        actor: *MainThreadProgress,
        handle: i64,
        task: *service_mod.ProgressService.Task,
    };
    pub const Host = struct {
        context: *anyopaque,
        cancel: *const fn (*anyopaque, i64) anyerror!void,
    };

    pub fn init(allocator: Allocator, service: *service_mod.ProgressService, host: Host) MainThreadProgress {
        return .{ .allocator = allocator, .service = service, .host = host, .entries = .init(allocator) };
    }

    pub fn deinit(self: *MainThreadProgress) void {
        var it = self.entries.valueIterator();
        while (it.next()) |value| {
            const entry = value.*;
            entry.task.dispose();
            self.allocator.destroy(entry);
        }
        self.entries.deinit();
    }

    pub fn invoke(self: *MainThreadProgress, method: []const u8, args: []const rpc.Arg) !rpc.HandlerReply {
        if (args.len == 0 or args[0] != .json or args[0].json != .integer) return error.InvalidArguments;
        const handle = args[0].json.integer;
        if (std.mem.eql(u8, method, "$startProgress")) {
            if (args.len < 2 or args[1] != .json or args[1].json != .object) return error.InvalidArguments;
            const opts = args[1].json.object;
            const location = opts.get("location") orelse return error.InvalidArguments;
            if (location != .integer) return error.UnsupportedProgressLocation;
            const parsed = std.enums.fromInt(progress.ProgressLocation, location.integer) orelse return error.UnsupportedProgressLocation;
            const title = stringField(opts, "title");
            const source: ?@import("../../../platform/notification/common/notification.zig").INotificationSource = if (opts.get("source")) |source| blk: {
                if (source == .object) break :blk .{ .id = stringField(source.object, "id") orelse "", .label = stringField(source.object, "label") orelse "" };
                if (source == .string) break :blk .{ .id = source.string, .label = source.string };
                break :blk null;
            } else null;
            const cancellable = if (opts.get("cancellable")) |value| value == .bool and value.bool else false;
            const extension_id = if (args.len > 2 and args[2] == .json and args[2].json == .string) args[2].json.string else "";
            const urgent = std.mem.eql(u8, extension_id, "vscode.github-authentication") or std.mem.eql(u8, extension_id, "vscode.microsoft-authentication");
            if (self.entries.fetchRemove(handle)) |old| {
                old.value.task.dispose();
                self.allocator.destroy(old.value);
            }
            const entry = try self.allocator.create(Entry);
            errdefer self.allocator.destroy(entry);
            entry.* = .{ .actor = self, .handle = handle, .task = undefined };
            entry.task = try self.service.start(.{ .location = parsed, .title = title, .source = source, .cancellable = cancellable, .urgent = urgent }, .{ .context = entry, .run = cancel });
            errdefer entry.task.dispose();
            try self.entries.put(handle, entry);
        } else if (std.mem.eql(u8, method, "$progressReport")) {
            const entry = self.entries.get(handle) orelse return .empty;
            if (args.len < 2 or args[1] != .json or args[1].json != .object) return error.InvalidArguments;
            const step = args[1].json.object;
            const increment: ?i64 = if (step.get("increment")) |value| switch (value) {
                .integer => value.integer,
                .float => |number| if (std.math.isFinite(number) and number >= 0 and number <= 100) @intFromFloat(number) else null,
                else => null,
            } else null;
            try entry.task.report(stringField(step, "message"), increment);
        } else if (std.mem.eql(u8, method, "$progressEnd")) {
            if (self.entries.fetchRemove(handle)) |entry| {
                entry.value.task.end();
                self.allocator.destroy(entry.value);
            }
        } else return error.UnsupportedMethod;
        return .empty;
    }

    fn cancel(context: *anyopaque) void {
        const entry: *Entry = @ptrCast(@alignCast(context));
        entry.actor.host.cancel(entry.actor.host.context, entry.handle) catch {};
    }
};

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}
