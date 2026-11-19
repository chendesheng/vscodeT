// Port of `src/vs/workbench/api/browser/mainThreadStatusBar.ts`.
//
// Terminal adaptation: the portable `StatusbarService` owns entry order,
// alignment and priority; theme colors, markdown/HTML tooltips and tooltip
// providers are reduced to plain text. The actor owns the entry strings because
// the status-bar part borrows them, and it disposes the accessor on `$disposeEntry`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const statusbar = @import("../../services/statusbar/browser/statusbar.zig");
const statusbar_part = @import("../../browser/parts/statusbar/statusbarPart.zig");
const EntryAccessor = statusbar_part.EntryAccessor;
const PriorityInput = statusbar_part.PriorityInput;
const StatusbarService = statusbar_part.StatusbarService;

pub const RefreshCallback = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque) void,
};

pub const MainThreadStatusBar = struct {
    allocator: Allocator,
    statusbar: *StatusbarService,
    refresh: ?RefreshCallback,
    entries: std.StringHashMap(OwnedEntry),

    const OwnedEntry = struct {
        accessor: EntryAccessor,
        name: []u8,
        text: []u8,
        tooltip: ?[]u8,
        aria_label: []u8,
        role: ?[]u8,
        extension_id: ?[]u8,
    };

    const OwnedFields = struct {
        name: []u8,
        text: []u8,
        tooltip: ?[]u8,
        aria_label: []u8,
        role: ?[]u8,
        extension_id: ?[]u8,
    };

    pub fn init(
        allocator: Allocator,
        statusbar_service: *StatusbarService,
        refresh: ?RefreshCallback,
    ) !MainThreadStatusBar {
        return .{
            .allocator = allocator,
            .statusbar = statusbar_service,
            .refresh = refresh,
            .entries = std.StringHashMap(OwnedEntry).init(allocator),
        };
    }

    pub fn deinit(self: *MainThreadStatusBar) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            var owned = entry.value_ptr.*;
            owned.accessor.dispose();
            freeFields(self.allocator, .{
                .name = owned.name,
                .text = owned.text,
                .tooltip = owned.tooltip,
                .aria_label = owned.aria_label,
                .role = owned.role,
                .extension_id = owned.extension_id,
            });
            self.allocator.free(key);
        }
        self.entries.deinit();
    }

    pub fn invoke(
        self: *MainThreadStatusBar,
        method: []const u8,
        args: []const rpc.Arg,
        arena: Allocator,
    ) !rpc.HandlerReply {
        _ = arena;
        if (std.mem.eql(u8, method, "$setEntry")) {
            self.setEntry(args) catch return .empty;
            self.refreshNow();
            return .empty;
        }
        if (std.mem.eql(u8, method, "$disposeEntry")) {
            if (args.len > 0 and args[0] == .json and args[0].json == .string) {
                self.disposeEntry(args[0].json.string);
                self.refreshNow();
            }
            return .empty;
        }
        if (methodKind(method) == .request) {
            return .{ .err = .{ .name = "Unsupported", .message = method } };
        }
        return .empty;
    }

    fn setEntry(self: *MainThreadStatusBar, args: []const rpc.Arg) !void {
        if (args.len < 11) return error.InvalidArguments;
        const entry_id = try stringArg(args, 0);
        const fields = try parseFields(self.allocator, args);
        errdefer freeFields(self.allocator, fields);
        const align_left = try boolArg(args, 10);
        const priority = numberArg(args, 11) orelse 0;

        if (self.entries.getPtr(entry_id)) |existing| {
            existing.accessor.update(.{
                .name = fields.name,
                .text = fields.text,
                .aria_label = fields.aria_label,
                .role = fields.role,
                .tooltip = fields.tooltip,
                .extension_id = fields.extension_id,
            });
            freeFields(self.allocator, .{
                .name = existing.name,
                .text = existing.text,
                .tooltip = existing.tooltip,
                .aria_label = existing.aria_label,
                .role = existing.role,
                .extension_id = existing.extension_id,
            });
            existing.name = fields.name;
            existing.text = fields.text;
            existing.tooltip = fields.tooltip;
            existing.aria_label = fields.aria_label;
            existing.role = fields.role;
            existing.extension_id = fields.extension_id;
            return;
        }

        const key = try self.allocator.dupe(u8, entry_id);
        errdefer self.allocator.free(key);
        const accessor = try self.statusbar.addEntry(.{
            .name = fields.name,
            .text = fields.text,
            .aria_label = fields.aria_label,
            .role = fields.role,
            .tooltip = fields.tooltip,
            .extension_id = fields.extension_id,
        }, key, if (align_left) .left else .right, PriorityInput{ .number = priority });
        try self.entries.put(key, .{
            .accessor = accessor,
            .name = fields.name,
            .text = fields.text,
            .tooltip = fields.tooltip,
            .aria_label = fields.aria_label,
            .role = fields.role,
            .extension_id = fields.extension_id,
        });
    }

    fn disposeEntry(self: *MainThreadStatusBar, entry_id: []const u8) void {
        if (self.entries.fetchRemove(entry_id)) |entry| {
            var owned = entry.value;
            owned.accessor.dispose();
            freeFields(self.allocator, .{
                .name = owned.name,
                .text = owned.text,
                .tooltip = owned.tooltip,
                .aria_label = owned.aria_label,
                .role = owned.role,
                .extension_id = owned.extension_id,
            });
            self.allocator.free(entry.key);
        }
    }

    fn refreshNow(self: *MainThreadStatusBar) void {
        if (self.refresh) |refresh| refresh.callback(refresh.context);
    }
};

fn parseFields(allocator: Allocator, args: []const rpc.Arg) !MainThreadStatusBar.OwnedFields {
    const name = try allocator.dupe(u8, try stringArg(args, 3));
    errdefer allocator.free(name);
    const text = try allocator.dupe(u8, try stringArg(args, 4));
    errdefer allocator.free(text);
    const tooltip = if (try optionalStringArg(args, 5)) |value| try allocator.dupe(u8, value) else null;
    errdefer if (tooltip) |value| allocator.free(value);
    const extension_id = if (try optionalStringArg(args, 2)) |value| try allocator.dupe(u8, value) else null;
    errdefer if (extension_id) |value| allocator.free(value);

    var aria_label: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(aria_label);
    var role: ?[]u8 = null;
    if (args.len > 12 and args[12] == .json and args[12].json == .object) {
        if (args[12].json.object.get("label")) |value| {
            if (value == .string) {
                allocator.free(aria_label);
                aria_label = try allocator.dupe(u8, value.string);
            }
        }
        if (args[12].json.object.get("role")) |value| {
            if (value == .string) role = try allocator.dupe(u8, value.string);
        }
    }
    return .{
        .name = name,
        .text = text,
        .tooltip = tooltip,
        .aria_label = aria_label,
        .role = role,
        .extension_id = extension_id,
    };
}

fn freeFields(allocator: Allocator, fields: MainThreadStatusBar.OwnedFields) void {
    allocator.free(fields.name);
    allocator.free(fields.text);
    if (fields.tooltip) |value| allocator.free(value);
    allocator.free(fields.aria_label);
    if (fields.role) |value| allocator.free(value);
    if (fields.extension_id) |value| allocator.free(value);
}

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadStatusBar.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

fn stringArg(args: []const rpc.Arg, index: usize) ![]const u8 {
    if (index >= args.len or args[index] != .json or args[index].json != .string) return error.InvalidArguments;
    return args[index].json.string;
}

fn optionalStringArg(args: []const rpc.Arg, index: usize) !?[]const u8 {
    if (index >= args.len or args[index] != .json) return null;
    if (args[index].json == .string) return args[index].json.string;
    if (args[index].json == .object) {
        if (args[index].json.object.get("value")) |value| {
            if (value == .string) return value.string;
        }
    }
    return null;
}

fn boolArg(args: []const rpc.Arg, index: usize) !bool {
    if (index >= args.len or args[index] != .json or args[index].json != .bool) return error.InvalidArguments;
    return args[index].json.bool;
}

fn numberArg(args: []const rpc.Arg, index: usize) ?f64 {
    if (index >= args.len or args[index] != .json) return null;
    return switch (args[index].json) {
        .integer => |value| @floatFromInt(value),
        .float => |value| value,
        else => null,
    };
}

test "MainThreadStatusBar: sets, updates and disposes an entry" {
    const allocator = std.testing.allocator;
    var service = try StatusbarService.init(allocator);
    defer service.deinit();
    var refreshed: usize = 0;
    const callback = struct {
        fn refresh(context: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(context));
            count.* += 1;
        }
    }.refresh;
    var actor = try MainThreadStatusBar.init(allocator, &service, .{ .context = &refreshed, .callback = callback });
    defer actor.deinit();

    var args = [_]rpc.Arg{
        .{ .json = .{ .string = "typescript.version" } },
        .{ .json = .{ .string = "typescript.version" } },
        .{ .json = .{ .string = "vscode.typescript-language-features" } },
        .{ .json = .{ .string = "TypeScript Version" } },
        .{ .json = .{ .string = "6.0.3" } },
        .{ .json = .null },
        .{ .json = .{ .bool = false } },
        .{ .json = .null },
        .{ .json = .null },
        .{ .json = .null },
        .{ .json = .{ .bool = true } },
        .{ .json = .{ .integer = 99 } },
        .{ .json = .null },
    };
    try std.testing.expectEqual(rpc.HandlerReply.empty, try actor.invoke("$setEntry", &args, allocator));
    try std.testing.expectEqual(@as(usize, 1), service.model().entries().len);
    try std.testing.expectEqualStrings("6.0.3", service.model().entries()[0].item.text());

    args[4] = .{ .json = .{ .string = "6.0.4" } };
    _ = try actor.invoke("$setEntry", &args, allocator);
    try std.testing.expectEqual(@as(usize, 1), service.model().entries().len);
    try std.testing.expectEqualStrings("6.0.4", service.model().entries()[0].item.text());

    var dispose = [_]rpc.Arg{.{ .json = .{ .string = "typescript.version" } }};
    _ = try actor.invoke("$disposeEntry", &dispose, allocator);
    try std.testing.expectEqual(@as(usize, 0), service.model().entries().len);
    try std.testing.expectEqual(@as(usize, 3), refreshed);
}
