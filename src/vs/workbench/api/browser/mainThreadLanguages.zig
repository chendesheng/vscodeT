// Port of the language-status part of
// `src/vs/workbench/api/browser/mainThreadLanguages.ts`.
// Each handle owns its DTO strings and registration. Language discovery and
// syntax highlighting requests are separate parts of the upstream actor.
const std = @import("std");
const language_status = @import("../../services/languageStatus/common/languageStatusService.zig");
const parseSelector = @import("../common/extHostTypeConverters.zig").parseSelector;
const linked_text = @import("../../../base/common/linkedText.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const IDisposable = @import("../../../base/common/lifecycle.zig").IDisposable;
const Severity = @import("../../../base/common/severity.zig").Severity;
const Command = @import("../../../editor/common/languages.zig").Command;
const Allocator = std.mem.Allocator;

pub const MainThreadLanguages = struct {
    allocator: Allocator,
    service: language_status.ILanguageStatusService,
    status: std.AutoHashMap(u32, *Entry),

    const Entry = struct {
        arena: std.heap.ArenaAllocator,
        registration: IDisposable = .none,
    };

    pub fn init(allocator: Allocator, service: language_status.ILanguageStatusService) MainThreadLanguages {
        return .{ .allocator = allocator, .service = service, .status = .init(allocator) };
    }

    pub fn deinit(self: *MainThreadLanguages) void {
        var values = self.status.valueIterator();
        while (values.next()) |entry| self.dispose(entry.*);
        self.status.deinit();
    }

    fn dispose(self: *MainThreadLanguages, entry: *Entry) void {
        entry.registration.dispose();
        entry.arena.deinit();
        self.allocator.destroy(entry);
    }

    fn remove(self: *MainThreadLanguages, handle: u32) void {
        if (self.status.fetchRemove(handle)) |entry| self.dispose(entry.value);
    }

    pub fn invoke(self: *MainThreadLanguages, method: []const u8, args: []const rpc.Arg) !rpc.HandlerReply {
        if (!std.mem.eql(u8, method, "$setLanguageStatus") and !std.mem.eql(u8, method, "$removeLanguageStatus")) return .{ .err = .{ .name = "Unsupported", .message = method } };
        if (args.len == 0 or args[0] != .json or args[0].json != .integer) return error.InvalidArguments;
        const handle = std.math.cast(u32, args[0].json.integer) orelse return error.InvalidArguments;
        if (std.mem.eql(u8, method, "$removeLanguageStatus")) {
            self.remove(handle);
            return .empty;
        }
        if (args.len < 2 or args[1] != .json or args[1].json != .object) return error.InvalidArguments;
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .arena = .init(self.allocator) };
        errdefer entry.arena.deinit();
        const arena = entry.arena.allocator();
        const dto = args[1].json.object;
        const label = dto.get("label") orelse return error.InvalidArguments;
        const text = if (label == .string) label.string else if (label == .object) field(label.object, "value") else "";
        const short = if (label == .object) optionalField(label.object, "shortValue") else null;
        const severity: std.json.Value = dto.get("severity") orelse .{ .integer = 0 };
        const busy: std.json.Value = dto.get("busy") orelse .{ .bool = false };
        const detail = try arena.dupe(u8, field(dto, "detail"));
        const value: language_status.ILanguageStatus = .{
            .id = try arena.dupe(u8, field(dto, "id")),
            .name = try arena.dupe(u8, field(dto, "name")),
            .selector = try parseSelector(arena, dto.get("selector") orelse return error.InvalidArguments),
            .severity = if (severity == .integer and severity.integer >= 0 and severity.integer <= 3) @fromBackingInt(@intCast(severity.integer)) else Severity.Ignore,
            .label = try arena.dupe(u8, text),
            .short_label = if (short) |label_text| try arena.dupe(u8, label_text) else null,
            .detail = try linked_text.parseLinkedText(arena, detail),
            .busy = busy == .bool and busy.bool,
            .source = try arena.dupe(u8, field(dto, "source")),
            .command = try parseCommand(arena, dto.get("command") orelse .null),
            .accessibility_label = try parseAccessibility(arena, dto.get("accessibilityInfo") orelse .null, "label"),
            .accessibility_role = try parseAccessibility(arena, dto.get("accessibilityInfo") orelse .null, "role"),
        };
        try self.status.ensureUnusedCapacity(1);
        self.remove(handle);
        entry.registration = try self.service.addStatus(value);
        self.status.putAssumeCapacity(handle, entry);
        return .empty;
    }
};

fn optionalField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn field(object: std.json.ObjectMap, name: []const u8) []const u8 {
    return optionalField(object, name) orelse "";
}

fn parseAccessibility(arena: Allocator, value: std.json.Value, name: []const u8) !?[]const u8 {
    if (value != .object) return null;
    const data = optionalField(value.object, name) orelse return null;
    return try arena.dupe(u8, data);
}

fn parseCommand(arena: Allocator, value: std.json.Value) !?Command {
    if (value != .object) return null;
    const id = optionalField(value.object, "id") orelse return null;
    const arguments = if (value.object.get("arguments")) |args| blk: {
        const serialized = try std.json.Stringify.valueAlloc(arena, args, .{});
        break :blk try std.json.parseFromSliceLeaky(std.json.Value, arena, serialized, .{ .allocate = .alloc_always });
    } else null;
    return .{ .id = try arena.dupe(u8, id), .title = try arena.dupe(u8, field(value.object, "title")), .arguments = arguments };
}
