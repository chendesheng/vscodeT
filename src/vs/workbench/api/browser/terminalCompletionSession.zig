// Extension-host terminal completion provider from src/vs/workbench/api/browser/mainThreadTerminalService.ts.
// Mirrors the active terminal into the Node host and converts its completion DTOs.
const std = @import("std");
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const protocol = @import("../common/extHost.protocol.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const proxy = @import("../../services/extensions/common/proxyIdentifier.zig").identifierFromEnum;
const shell_integration = proxy(protocol.ExtHostContext.ExtHostTerminalShellIntegration);
const api = @import("../../contrib/terminalContrib/suggest/browser/terminalCompletionService.zig");
const TerminalInstance = @import("../../contrib/terminal/browser/terminalInstance.zig").TerminalInstance;
const actor = proxy(protocol.ExtHostContext.ExtHostTerminalService);

pub const Session = struct {
    host: *manager.HostManager,
    allocator: std.mem.Allocator,
    mirrored_terminal: ?usize = null,
    pending: ?u32 = null,
    results: ?api.Results = null,
    command_line: ?[]u8 = null,
    cursor: usize = 0,

    pub fn interface(self: *Session) api.ITerminalCompletionService {
        return .{ .context = self, .provide = provide, .cancel_fn = cancel };
    }

    fn cancel(context: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(context));
        if (self.pending) |id| self.host.rpc.cancel(id);
        self.pending = null;
        self.results = null;
        if (self.command_line) |line| self.allocator.free(line);
        self.command_line = null;
    }

    fn provide(context: *anyopaque, instance: *TerminalInstance, line: []const u8, cursor: usize, results: api.Results) !void {
        const self: *Session = @ptrCast(@alignCast(context));
        cancel(self);
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const terminal_id = rpc.Arg{ .json = .{ .integer = @intCast(instance.id) } };
        if (self.mirrored_terminal != instance.id) {
            if (self.mirrored_terminal) |old| try self.host.notify(actor, "$acceptTerminalClosed", &.{ .{ .json = .{ .integer = @intCast(old) } }, .undefined, .{ .json = .{ .integer = 0 } } });
            var launch: std.json.ObjectMap = .empty;
            if (instance.cwd orelse instance.initial_cwd) |cwd| try launch.put(a, "cwd", .{ .string = cwd });
            try self.host.notify(actor, "$acceptTerminalOpened", &.{ terminal_id, .undefined, .{ .json = .{ .string = instance.displayTitle() } }, .{ .json = .{ .object = launch } } });
            try self.host.notify(shell_integration, "$shellIntegrationChange", &.{ terminal_id, .{ .json = .{ .bool = false } } });
            self.mirrored_terminal = instance.id;
        }
        if (instance.cwd orelse instance.initial_cwd) |cwd| {
            try self.host.notify(shell_integration, "$cwdChange", &.{ terminal_id, .{ .json = .{ .string = cwd } } });
        }
        if (instance.shell_type) |shell| try self.host.notify(actor, "$acceptTerminalShellType", &.{ terminal_id, .{ .json = .{ .string = @tagName(shell) } } });
        try self.host.notify(actor, "$acceptActiveTerminalChanged", &.{terminal_id});
        // Activation is a separate RPC promise. Its reply is dispatched on
        // the window, so the terminal remains responsive while the provider
        // extension starts. Keep only owned inputs across that boundary.
        self.command_line = try self.allocator.dupe(u8, line);
        self.cursor = cursor;
        self.results = results;
        errdefer cancel(self);
        self.pending = try self.host.call(proxy(protocol.ExtHostContext.ExtHostExtensionService), "$activateByEvent", &.{ .{ .json = .{ .string = "onTerminalShellIntegration:*" } }, .{ .json = .{ .integer = 0 } } }, null, .{ .context = self, .callback = activated });
    }

    fn activated(context: *anyopaque, reply: rpc.Reply) void {
        const self: *Session = @ptrCast(@alignCast(context));
        self.pending = null;
        const line = self.command_line orelse return;
        self.command_line = null;
        defer self.allocator.free(line);
        if (reply == .err) return receive(context, reply);
        self.requestCompletions(line) catch receive(context, .{ .err = .{ .name = "Error", .message = "Could not request terminal completions" } });
    }

    fn requestCompletions(self: *Session, line: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var ctx: std.json.ObjectMap = .empty;
        try ctx.put(a, "commandLine", .{ .string = line });
        try ctx.put(a, "cursorIndex", .{ .integer = @intCast(self.cursor) });
        self.pending = try self.host.call(actor, "$provideTerminalCompletions", &.{ .{ .json = .{ .string = "vscode.terminal-suggest" } }, .{ .json = .{ .object = ctx } } }, null, .{ .context = self, .callback = receive });
    }

    fn receive(context: *anyopaque, reply: rpc.Reply) void {
        const self: *Session = @ptrCast(@alignCast(context));
        self.pending = null;
        const results = self.results orelse return;
        self.results = null;
        var items: std.ArrayList(api.Completion) = .empty;
        defer items.deinit(self.allocator);
        if (reply == .json and reply.json == .object) {
            if (reply.json.object.get("items")) |entries| {
                if (entries == .array) for (entries.array.items) |entry| {
                    const completion = parseCompletion(entry) orelse continue;
                    items.append(self.allocator, completion) catch break;
                };
            }
        }
        results.accept(results.context, items.items);
    }
};

fn parseCompletion(entry: std.json.Value) ?api.Completion {
    if (entry != .object) return null;
    const raw = entry.object.get("label") orelse return null;
    const label = if (raw == .object) raw.object.get("label") orelse return null else raw;
    const range = entry.object.get("replacementRange") orelse return null;
    if (label != .string or range != .array or range.array.items.len != 2) return null;
    const start, const end = range.array.items[0..2].*;
    if (start != .integer or end != .integer) return null;
    return .{ .label = label.string, .replacement_range = .{
        std.math.cast(usize, start.integer) orelse return null,
        std.math.cast(usize, end.integer) orelse return null,
    } };
}
