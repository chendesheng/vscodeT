// Port of ForwardPortAction and ClosePortAction's palette handlers in
// src/vs/workbench/contrib/remote/browser/tunnelView.ts. The terminal quick
// input presents the prompts. Its private tunnel provider accepts local ports.
const std = @import("std");
const api = @import("../../../api/common/extensionApi.zig");
const model = @import("../../../services/remote/common/tunnelModel.zig");
const TunnelService = @import("../../../../platform/tunnel/common/tunnel.zig").TunnelService;
const QuickInputService = @import("../../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const QuickPick = @import("../../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const Item = @import("../../../../platform/quickinput/common/quickInput.zig").QuickPickItem;

const forward_id = "remote.tunnel.forwardCommandPalette";
const close_id = "remote.tunnel.closeCommandPalette";

pub const TunnelView = struct {
    commands: api.ICommandService,
    window: api.IWindowService,
    quick_input: *QuickInputService,
    tunnels: *TunnelService,
    arena: std.heap.ArenaAllocator,
    registrations: [2]api.IDisposable = @splat(.none),

    pub fn init(self: *TunnelView, api_context: *const api.IExtensionContext, quick_input: *QuickInputService, tunnels: *TunnelService) !void {
        self.* = .{ .commands = api_context.commands, .window = api_context.window, .quick_input = quick_input, .tunnels = tunnels, .arena = .init(api_context.allocator) };
        errdefer self.deinit();
        self.registrations[0] = try self.commands.register(forward_id, "Forward a Port", .{ .category = "Ports", .context = self, .run = choosePort });
        self.registrations[1] = try self.commands.register(close_id, "Stop Forwarding Port", .{ .category = "Ports", .context = self, .run = chooseTunnel });
    }

    pub fn deinit(self: *TunnelView) void {
        if (self.quick_input.handler_context == @as(*anyopaque, @ptrCast(self))) self.quick_input.hide();
        for (self.registrations) |registration| registration.dispose();
        self.arena.deinit();
    }

    fn choosePort(context: *anyopaque) !void {
        const self: *TunnelView = @ptrCast(@alignCast(context));
        try self.quick_input.showPick(&.{}, .{ .placeholder = "Port number or address (eg. 3000 or 10.10.10.10:2000).", .allow_free_input = true }, forward, self);
    }

    fn forward(context: *anyopaque, picker: *QuickPick) !void {
        const self: *TunnelView = @ptrCast(@alignCast(context));
        const parsed = model.parseAddress(picker.value.items) orelse return self.window.setMessage("Forwarded port should be a number or a host:port.");
        if (parsed.port >= 65536) return self.window.setMessage("Port number must be ≥ 0 and < 65536.");
        self.tunnels.openTunnel(.{ .host = parsed.host, .port = @intCast(parsed.port) }) catch |err| {
            self.window.setMessage(switch (err) {
                error.PortAlreadyForwarded => "Port is already forwarded",
                error.ExecutableNotFound => "Install the Microsoft Dev Tunnels CLI and add devtunnel to PATH",
                error.OnlyLocalPortsSupported => "The Dev Tunnels CLI forwards local ports only",
                error.InvalidLocalPort => "Enter a port between 1 and 65535",
                else => return err,
            });
        };
    }

    fn chooseTunnel(context: *anyopaque) !void {
        const self: *TunnelView = @ptrCast(@alignCast(context));
        if (self.quick_input.isVisible()) self.quick_input.hide();
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        const tunnels = try self.tunnels.getTunnels(arena);
        var picks: std.ArrayList(Item) = .empty;
        for (tunnels) |entry| {
            try picks.append(arena, .{ .item = .{
                .id = try std.fmt.allocPrint(arena, "{s}:{d}", .{ entry.host, entry.port }),
                .label = try std.fmt.allocPrint(arena, "Port {d}", .{entry.port}),
            } });
        }
        if (picks.items.len == 0) try picks.append(arena, .{ .item = .{ .label = "No ports currently forwarded. Try running the Forward a Port command" } });
        try self.quick_input.showPick(picks.items, .{ .placeholder = "Choose a port to stop forwarding" }, stop, self);
    }

    fn stop(context: *anyopaque, picker: *QuickPick) !void {
        const self: *TunnelView = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse return;
        if (model.parseAddress(item.id)) |address| {
            if (address.port < 65536) self.tunnels.closeTunnel(.{ .host = address.host, .port = @intCast(address.port) });
        } else {
            _ = try self.commands.execute(forward_id);
        }
    }
};
