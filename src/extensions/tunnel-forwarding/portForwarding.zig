// Terminal adaptation of extensions/tunnel-forwarding/src/extension.ts.
// registerTunnelProvider exposes private local tunnels. The Dev Tunnels CLI
// handles sign-in and each process has its own integrated terminal.
const std = @import("std");
const api = @import("../../vs/workbench/api/common/extensionApi.zig");
const tunnel = @import("../../vs/platform/tunnel/common/tunnel.zig");

pub const TunnelProvider = struct {
    allocator: std.mem.Allocator,
    terminals: api.TerminalCollection,
    active: std.ArrayList(struct { port: u16, terminal: usize }) = .empty,
    registration: api.IDisposable = .none,

    pub fn activate(self: *TunnelProvider, context: *const api.IExtensionContext) !void {
        self.* = .{ .allocator = context.allocator, .terminals = context.window.terminals orelse return error.Unsupported };
        self.registration = try context.workspace.registerTunnelProvider(self.interface());
    }

    pub fn deinit(self: *TunnelProvider) void {
        self.registration.dispose();
        self.active.deinit(self.allocator);
    }

    pub fn interface(self: *TunnelProvider) tunnel.ITunnelProvider {
        return .{ .context = self, .forward_port = provideTunnel, .tunnels = tunnels, .close_tunnel = closeTunnel };
    }

    fn provideTunnel(context: *anyopaque, address: tunnel.Address) !void {
        const self: *TunnelProvider = @ptrCast(@alignCast(context));
        if (!std.ascii.eqlIgnoreCase(address.host, "localhost") and
            !std.mem.eql(u8, address.host, "127.0.0.1") and !std.mem.eql(u8, address.host, "0.0.0.0")) return error.OnlyLocalPortsSupported;
        if (address.port == 0) return error.InvalidLocalPort;
        self.forgetStopped();
        for (self.active.items) |entry| {
            if (entry.port == address.port) return error.PortAlreadyForwarded;
        }
        try self.active.ensureUnusedCapacity(self.allocator, 1);
        var number_buf: [5]u8 = undefined;
        var name_buf: [32]u8 = undefined;
        const number = try std.fmt.bufPrint(&number_buf, "{d}", .{address.port});
        const name = try std.fmt.bufPrint(&name_buf, "Forward Port {s}", .{number});
        const id = try self.terminals.create(self.terminals.context, .{ .name = name, .shell_path = "devtunnel", .shell_args = &.{ "host", "-p", number } });
        self.active.appendAssumeCapacity(.{ .port = address.port, .terminal = id });
    }

    fn forgetStopped(self: *TunnelProvider) void {
        var i = self.active.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.terminals.running(self.terminals.context, self.active.items[i].terminal)) _ = self.active.orderedRemove(i);
        }
    }

    fn tunnels(context: *anyopaque, allocator: std.mem.Allocator) ![]const tunnel.Address {
        const self: *TunnelProvider = @ptrCast(@alignCast(context));
        self.forgetStopped();
        const result = try allocator.alloc(tunnel.Address, self.active.items.len);
        for (result, self.active.items) |*address, entry| address.* = .{ .host = "localhost", .port = entry.port };
        return result;
    }

    fn closeTunnel(context: *anyopaque, address: tunnel.Address) void {
        const self: *TunnelProvider = @ptrCast(@alignCast(context));
        for (self.active.items) |entry| {
            if (entry.port == address.port and self.terminals.running(self.terminals.context, entry.terminal)) {
                self.terminals.send_text(self.terminals.context, entry.terminal, "\x03");
                return;
            }
        }
    }
};
