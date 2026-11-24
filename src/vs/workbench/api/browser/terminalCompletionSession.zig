// Bridges manually requested shell completions to the upstream Terminal Suggest
// extension. Only the current command's input cells are passed to the provider.
const std = @import("std");
const Workbench = @import("../../browser/workbench.zig").Workbench;
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const protocol = @import("../common/extHost.protocol.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const proxy = @import("../../services/extensions/common/proxyIdentifier.zig").identifierFromEnum;
const shell_integration = proxy(protocol.ExtHostContext.ExtHostTerminalShellIntegration);
const positions = @import("../common/positionConverter.zig");
const QuickPick = @import("../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const Item = @import("../../../platform/quickinput/common/quickInput.zig").QuickPickItem;
const actor = proxy(protocol.ExtHostContext.ExtHostTerminalService);
pub const command = "workbench.action.terminal.requestCompletions";

pub const Session = struct {
    workbench: *Workbench,
    host: *manager.HostManager,
    arena: std.heap.ArenaAllocator,
    terminal: ?usize = null,
    line: []const u8 = "",
    pending: ?u32 = null,
    changed: bool = false,

    pub fn deinit(self: *Session) void {
        if (self.pending) |id| self.host.rpc.cancel(id);
        self.workbench.commands.unregister(command);
        self.arena.deinit();
    }

    pub fn request(context: *anyopaque) !void {
        const self: *Session = @ptrCast(@alignCast(context));
        const instance = self.workbench.focusedTerminal() orelse return;
        const shell = instance.shell_type orelse return;
        if (self.pending) |id| self.host.rpc.cancel(id);
        self.pending = null;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        self.line = try instance.emulator.promptInput(a) orelse return;
        const terminal_id = rpc.Arg{ .json = .{ .integer = @intCast(instance.id) } };
        if (self.terminal != instance.id) {
            if (self.terminal) |old| try self.host.notify(actor, "$acceptTerminalClosed", &.{ .{ .json = .{ .integer = @intCast(old) } }, .undefined, .{ .json = .{ .integer = 0 } } });
            var launch: std.json.ObjectMap = .empty;
            if (instance.cwd orelse instance.initial_cwd) |cwd| try launch.put(a, "cwd", .{ .string = cwd });
            try self.host.notify(actor, "$acceptTerminalOpened", &.{ terminal_id, .undefined, .{ .json = .{ .string = instance.displayTitle() } }, .{ .json = .{ .object = launch } } });
            try self.host.notify(shell_integration, "$shellIntegrationChange", &.{ terminal_id, .{ .json = .{ .bool = false } } });
            self.terminal = instance.id;
        }
        if (instance.cwd orelse instance.initial_cwd) |cwd| {
            try self.host.notify(shell_integration, "$cwdChange", &.{ terminal_id, .{ .json = .{ .string = cwd } } });
        }
        try self.host.notify(actor, "$acceptTerminalShellType", &.{ terminal_id, .{ .json = .{ .string = @tagName(shell) } } });
        try self.host.notify(actor, "$acceptActiveTerminalChanged", &.{terminal_id});
        _ = try self.host.requestSync(a, proxy(protocol.ExtHostContext.ExtHostExtensionService), "$activateByEvent", &.{ .{ .json = .{ .string = "onTerminalShellIntegration:*" } }, .{ .json = .{ .integer = 0 } } }, null, 5000);
        var ctx: std.json.ObjectMap = .empty;
        try ctx.put(a, "commandLine", .{ .string = self.line });
        try ctx.put(a, "cursorIndex", .{ .integer = @intCast(positions.utf16OffsetForColumn(self.line, self.line.len + 1) - 1) });
        self.pending = try self.host.call(actor, "$provideTerminalCompletions", &.{ .{ .json = .{ .string = "vscode.terminal-suggest" } }, .{ .json = .{ .object = ctx } } }, null, .{ .context = self, .callback = receive });
    }

    fn receive(context: *anyopaque, reply: rpc.Reply) void {
        const self: *Session = @ptrCast(@alignCast(context));
        self.pending = null;
        if (reply != .json or reply.json != .object) return;
        const items = reply.json.object.get("items") orelse return;
        if (items != .array) return;
        self.show(items.array.items) catch {};
    }

    fn show(self: *Session, entries: []const std.json.Value) !void {
        const a = self.arena.allocator();
        const instance = self.workbench.focusedTerminal() orelse return;
        if (instance.id != self.terminal or self.workbench.quick_access.isOpen()) return;
        const current = try instance.emulator.promptInput(a) orelse return;
        if (!std.mem.eql(u8, current, self.line)) return;
        var items: std.ArrayList(Item) = .empty;
        const end = positions.utf16OffsetForColumn(self.line, self.line.len + 1) - 1;
        for (entries) |entry| {
            if (entry != .object) continue;
            const label_data = entry.object.get("label") orelse continue;
            const label = if (label_data == .object) label_data.object.get("label") orelse continue else label_data;
            const range = entry.object.get("replacementRange") orelse continue;
            if (label != .string or range != .array or range.array.items.len != 2) continue;
            const bounds = range.array.items;
            if (bounds[0] != .integer or bounds[1] != .integer or bounds[0].integer < 0 or bounds[1].integer != end or bounds[0].integer > end) continue;
            const column = positions.columnForUtf16Offset(self.line, @as(usize, @intCast(bounds[0].integer)) + 1);
            const prefix = self.line[column - 1 ..];
            if (!std.mem.startsWith(u8, label.string, prefix) or label.string.len == prefix.len) continue;
            for (label.string) |c| {
                if (c < 32 or c == 127) break;
            } else {
                const owned = try a.dupe(u8, label.string);
                try items.append(a, .{ .item = .{ .id = owned[prefix.len..], .label = owned } });
            }
        }
        if (items.items.len == 0) return;
        try self.workbench.quick_access.inputService().showPick(items.items, .{ .placeholder = "Select a terminal suggestion" }, accept, self);
        self.changed = true;
    }

    fn accept(context: *anyopaque, picker: *QuickPick) !void {
        const self: *Session = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse return;
        const service = self.workbench.terminal_service orelse return;
        for (0..service.instanceCount()) |i| {
            const instance = service.instanceAt(i).?;
            if (instance.id != self.terminal) continue;
            const line = try instance.emulator.promptInput(self.arena.allocator()) orelse return;
            if (std.mem.eql(u8, line, self.line)) instance.writeInput(item.id);
            return;
        }
    }
};
