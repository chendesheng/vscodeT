// Interop test with the pinned Node extension host. This is the S2 smoke
// test from docs/extensions.md: boot the host, initialize workspace and
// configuration and start the extension host.
//
// It needs Node, the bundled launcher (host/dist/extensionHost.mjs) and the
// TypeScript fixture, so it only runs in the e2e build (build option
// `e2e`), which the `test-e2e` step enables
// and both paths exist. `zig build test` therefore stays hermetic.
const std = @import("std");
const build_options = @import("build_options");
const time_compat = @import("../../../../../base/common/timeCompat.zig");
const manager = @import("../../common/extensionHostManager.zig");
const rpc = @import("../../common/rpcProtocol.zig");
const proxyIdentifier = @import("../../common/proxyIdentifier.zig");
const protocol = @import("../../../../api/common/extHost.protocol.zig");

const Activation = struct {
    activated: bool = false,
    identifier: ?[]u8 = null,
    runtime_error: ?[]u8 = null,

    fn deinit(self: *Activation, allocator: std.mem.Allocator) void {
        if (self.identifier) |text| allocator.free(text);
        if (self.runtime_error) |text| allocator.free(text);
    }
};

const Doc = struct {
    lines: std.array_list.Managed([]u8),
    version: u32 = 1,
    cursor_line: usize = 1,
    cursor_column: usize = 1,
    decoration_count: usize = 0,

    fn deinit(self: *Doc, allocator: std.mem.Allocator) void {
        for (self.lines.items) |line| allocator.free(line);
        self.lines.deinit();
    }
};

const ActorSlot = struct {
    nid: u8,
    activation: *Activation,
    allocator: std.mem.Allocator,
    doc: *Doc,
    host: ?*manager.HostManager = null,

    fn insertAtCursor(self: *ActorSlot, arena: std.mem.Allocator, text: []const u8) !void {
        if (self.doc.lines.items.len == 0) try self.doc.lines.append(try self.allocator.dupe(u8, ""));
        const line_index = @min(self.doc.cursor_line - 1, self.doc.lines.items.len - 1);
        const old_line = self.doc.lines.items[line_index];
        const column = @min(self.doc.cursor_column - 1, old_line.len);
        const new_line = try std.mem.concat(self.allocator, u8, &.{ old_line[0..column], text, old_line[column..] });
        self.allocator.free(old_line);
        self.doc.lines.items[line_index] = new_line;
        self.doc.version += 1;
        const insert_column = self.doc.cursor_column;
        self.doc.cursor_column += text.len;

        const host = self.host orelse return;
        var changes = std.json.Array.init(arena);
        var change: std.json.ObjectMap = .empty;
        try change.put(arena, "rangeOffset", .{ .integer = 0 });
        try change.put(arena, "rangeLength", .{ .integer = 0 });
        try change.put(arena, "text", .{ .string = try arena.dupe(u8, text) });
        var range: std.json.ObjectMap = .empty;
        try range.put(arena, "startLineNumber", .{ .integer = @intCast(self.doc.cursor_line) });
        try range.put(arena, "startColumn", .{ .integer = @intCast(insert_column) });
        try range.put(arena, "endLineNumber", .{ .integer = @intCast(self.doc.cursor_line) });
        try range.put(arena, "endColumn", .{ .integer = @intCast(insert_column) });
        try change.put(arena, "range", .{ .object = range });
        try changes.append(.{ .object = change });
        var event: std.json.ObjectMap = .empty;
        try event.put(arena, "changes", .{ .array = changes });
        try event.put(arena, "eol", .{ .string = "\n" });
        try event.put(arena, "versionId", .{ .integer = @intCast(self.doc.version) });
        try event.put(arena, "isUndoing", .{ .bool = false });
        try event.put(arena, "isRedoing", .{ .bool = false });
        try event.put(arena, "isFlush", .{ .bool = false });
        try event.put(arena, "isEolChange", .{ .bool = false });
        try event.put(arena, "detailedReason", .null);
        const args = [_]rpc.Arg{
            .{ .json = try manager.fileUri(arena, "/tmp/vim-test.txt") },
            .{ .json = .{ .object = event } },
            .{ .json = .{ .bool = false } },
        };
        _ = host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocuments), "$acceptModelChanged", &args, null, manager.noop_callback) catch {};
    }

    fn handler(self: *ActorSlot) rpc.ActorHandler {
        return .{ .context = self, .invoke = invoke };
    }

    fn invoke(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../../../base/common/cancellation.zig").CancellationToken, arena: std.mem.Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *ActorSlot = @ptrCast(@alignCast(context));

        if (std.mem.eql(u8, method, "$registerTextEditorDecorationType")) {
            self.doc.decoration_count += 1;
            var key_buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "decoration-{d}", .{self.doc.decoration_count});
            return .{ .json = .{ .string = try arena.dupe(u8, key) } };
        }
        if (std.mem.eql(u8, method, "$trySetSelections")) {
            if (args.len > 1 and args[1] == .json and args[1].json == .array and args[1].json.array.items.len > 0) {
                const selection = args[1].json.array.items[0];
                if (selection == .object) {
                    if (selection.object.get("positionLineNumber")) |line| {
                        if (line == .integer) self.doc.cursor_line = @intCast(line.integer);
                    }
                    if (selection.object.get("positionColumn")) |column| {
                        if (column == .integer) self.doc.cursor_column = @intCast(column.integer);
                    }
                }
            }
            return .{ .json = .{ .bool = true } };
        }
        if (std.mem.eql(u8, method, "$tryApplyEdits")) {
            return .{ .json = .{ .bool = true } };
        }
        if (std.mem.eql(u8, method, "$executeCommand")) {
            const command = if (args.len > 0 and args[0] == .json and args[0].json == .string) args[0].json.string else "";
            if (std.mem.eql(u8, command, "default:type")) {
                if (args.len > 1 and args[1] == .json and args[1].json == .array and args[1].json.array.items.len > 0) {
                    const first = args[1].json.array.items[0];
                    if (first == .object) {
                        if (first.object.get("text")) |value| {
                            if (value == .string) try self.insertAtCursor(arena, value.string);
                        }
                    }
                }
                return .empty;
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$getInitialState")) {
            var state: std.json.ObjectMap = .empty;
            try state.put(arena, "isFocused", .{ .bool = true });
            try state.put(arena, "isActive", .{ .bool = true });
            return .{ .json = .{ .object = state } };
        }
        if (std.mem.eql(u8, method, "$getTools")) {
            return .{ .json = .{ .array = std.json.Array.init(arena) } };
        }
        if (std.mem.eql(u8, method, "$ensureActivation")) {
            return .{ .json = .{ .bool = true } };
        }
        if (std.mem.eql(u8, method, "$onDidActivateExtension")) {
            if (args.len > 0 and args[0] == .json and args[0].json == .object) {
                if (args[0].json.object.get("value")) |value| {
                    if (value == .string) {
                        if (self.activation.identifier) |old| self.allocator.free(old);
                        self.activation.identifier = try self.allocator.dupe(u8, value.string);
                        self.activation.activated = true;
                    }
                }
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$onExtensionActivationError")) {
            if (args.len > 1 and args[1] == .json and args[1].json == .object) {
                if (args[1].json.object.get("message")) |value| {
                    if (value == .string) {
                        if (self.activation.runtime_error) |old| self.allocator.free(old);
                        self.activation.runtime_error = try self.allocator.dupe(u8, value.string);
                    }
                }
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$onExtensionRuntimeError") or std.mem.eql(u8, method, "$onUnexpectedError")) {
            if (args.len > 0 and args[0] == .json and args[0].json == .object) {
                if (args[0].json.object.get("message")) |value| {
                    if (value == .string) {
                        if (self.activation.runtime_error) |old| self.allocator.free(old);
                        self.activation.runtime_error = try self.allocator.dupe(u8, value.string);
                    }
                }
            }
            return .empty;
        }
        _ = self.nid;
        return .empty;
    }
};

const WaitFlag = struct {
    done: bool = false,

    fn callback(context: *anyopaque, reply: rpc.Reply) void {
        const self: *WaitFlag = @ptrCast(@alignCast(context));
        _ = reply;
        self.done = true;
    }
};

fn done(context: *anyopaque) bool {
    const flag: *WaitFlag = @ptrCast(@alignCast(context));
    return flag.done;
}

fn activated(context: *anyopaque) bool {
    const activation: *Activation = @ptrCast(@alignCast(context));
    return activation.activated or activation.runtime_error != null;
}

fn emptyConfig(arena: std.mem.Allocator) !std.json.Value {
    var root: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "defaults", "policy", "application", "userLocal", "userRemote", "workspace" }) |key| {
        var model: std.json.ObjectMap = .empty;
        try model.put(arena, "contents", .{ .object = .empty });
        try model.put(arena, "keys", .{ .array = std.json.Array.init(arena) });
        try model.put(arena, "overrides", .{ .array = std.json.Array.init(arena) });
        try root.put(arena, key, .{ .object = model });
    }
    try root.put(arena, "folders", .{ .array = std.json.Array.init(arena) });
    try root.put(arena, "configurationScopes", .{ .array = std.json.Array.init(arena) });
    return .{ .object = root };
}
