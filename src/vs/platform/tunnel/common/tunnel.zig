// Port of the registered tunnel provider boundary in src/vs/platform/tunnel/common/tunnel.ts.
// The terminal provider exposes private, local forwards managed by its Dev Tunnels process.
const std = @import("std");
const IDisposable = @import("../../../base/common/lifecycle.zig").IDisposable;

pub const Address = struct { host: []const u8, port: u16 };

pub const ITunnelProvider = struct {
    context: *anyopaque,
    forward_port: *const fn (*anyopaque, Address) anyerror!void,
    tunnels: *const fn (*anyopaque, std.mem.Allocator) anyerror![]const Address,
    close_tunnel: *const fn (*anyopaque, Address) void,
};

pub const TunnelService = struct {
    provider: ?ITunnelProvider = null,

    pub fn setTunnelProvider(self: *TunnelService, provider: ITunnelProvider) !IDisposable {
        if (self.provider != null) return error.TunnelProviderAlreadyRegistered;
        self.provider = provider;
        return .{ .context = self, .disposeFn = removeProvider };
    }

    fn removeProvider(context: *anyopaque) void {
        const self: *TunnelService = @ptrCast(@alignCast(context));
        self.provider = null;
    }

    pub fn openTunnel(self: *TunnelService, address: Address) !void {
        const provider = self.provider orelse return error.NoTunnelProvider;
        return provider.forward_port(provider.context, address);
    }

    pub fn getTunnels(self: *TunnelService, allocator: std.mem.Allocator) ![]const Address {
        const provider = self.provider orelse return &.{};
        return provider.tunnels(provider.context, allocator);
    }

    pub fn closeTunnel(self: *TunnelService, address: Address) void {
        if (self.provider) |provider| provider.close_tunnel(provider.context, address);
    }
};
