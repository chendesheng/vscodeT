// Port of `src/vs/workbench/api/browser/mainThreadLogService.ts`.
const std = @import("std");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const std_uri = @import("../../../base/common/stdUri.zig");
const FileLoggerService = @import("../../../platform/log/common/fileLog.zig").FileLoggerService;
const LogLevel = @import("../../../platform/log/common/log.zig").LogLevel;
const Allocator = std.mem.Allocator;

pub const MainThreadLoggerService = struct {
    service: *FileLoggerService,

    pub fn invoke(self: *MainThreadLoggerService, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (args.len == 0 or args[0] != .json) return error.InvalidArguments;
        if (std.mem.eql(u8, method, "$registerLogger")) {
            if (args[0].json != .object) return error.InvalidArguments;
            const dto = args[0].json.object;
            const resource = try uri(arena, dto.get("resource") orelse return error.InvalidArguments);
            _ = try self.service.registerLogger(resource, parseOptions(args[0].json));
            return .empty;
        }
        const resource = try uri(arena, args[0].json);
        if (std.mem.eql(u8, method, "$createLogger")) {
            try self.service.createLogger(resource, parseOptions(if (args.len > 1 and args[1] == .json) args[1].json else .null));
        } else if (std.mem.eql(u8, method, "$log")) {
            if (args.len < 2 or args[1] != .json or args[1].json != .array) return error.InvalidArguments;
            const messages = args[1].json.array.items;
            const entries = try arena.alloc(FileLoggerService.Entry, messages.len);
            for (messages, entries) |message, *entry| {
                if (message != .array or message.array.items.len != 2) return error.InvalidArguments;
                const level = message.array.items[0];
                const text = message.array.items[1];
                if (level != .integer or level.integer < 0 or level.integer > 5 or text != .string) return error.InvalidArguments;
                entry.* = .{ .level = @fromBackingInt(@intCast(level.integer)), .message = text.string };
            }
            try self.service.appendBatch(resource, entries);
        } else if (std.mem.eql(u8, method, "$flush")) {
            // FileLoggerService writes are synchronous at the native file
            // service boundary; the bytes are already available to the view.
            if ((try self.service.getLogger(resource)) == null) return error.LoggerNotCreated;
        } else if (std.mem.eql(u8, method, "$deregisterLogger")) {
            try self.service.deregisterLogger(resource);
        } else if (std.mem.eql(u8, method, "$setVisibility")) {
            if (args.len < 2 or args[1] != .json or args[1].json != .bool) return error.InvalidArguments;
            try self.service.setVisibility(resource, args[1].json.bool);
        } else return .{ .err = .{ .name = "Unsupported", .message = method } };
        return .empty;
    }
};

fn uri(arena: Allocator, value: std.json.Value) !std.Uri {
    return std.Uri.parse(try std_uri.encodedResourceFromJson(arena, value));
}

fn parseOptions(value: std.json.Value) FileLoggerService.Options {
    if (value != .object) return .{};
    const object = value.object;
    const level = object.get("logLevel") orelse std.json.Value.null;
    return .{
        .id = string(object, "id"),
        .name = string(object, "name"),
        .extension_id = string(object, "extensionId"),
        .level = if (level == .integer and level.integer >= 0 and level.integer <= 5) @fromBackingInt(@intCast(level.integer)) else LogLevel.trace,
        .raw = boolean(object, "donotUseFormatters"),
        .hidden = boolean(object, "hidden"),
        .no_rotation = boolean(object, "donotRotate"),
    };
}

fn string(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}
fn boolean(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return value == .bool and value.bool;
}
