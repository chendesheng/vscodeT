// Port actions for the terminal workbench. The Microsoft Dev Tunnels CLI owns
// sign-in, the temporary private tunnel, and its lifetime in the terminal.
const std = @import("std");
const Workbench = @import("../../vs/workbench/browser/workbench.zig").Workbench;
const QuickPick = @import("../../vs/platform/quickinput/browser/quickInput.zig").QuickPick;
const Item = @import("../../vs/platform/quickinput/common/quickInput.zig").QuickPickItem;

pub fn register(w: *Workbench) !void {
    try w.commands.register(.{ .id = "remote.tunnel.forwardCommandPalette", .label = "Forward a Port", .category = "Ports", .context = w, .run = choosePort });
    try w.commands.register(.{ .id = "remote.tunnel.closeCommandPalette", .label = "Stop Forwarding Port", .category = "Ports", .context = w, .run = chooseTunnel });
}

fn choosePort(context: *anyopaque) !void {
    const w: *Workbench = @ptrCast(@alignCast(context));
    try w.quick_access.inputService().showPick(&.{}, .{ .placeholder = "Local port to forward privately (1–65535)", .allow_free_input = true }, forward, w);
}

fn forward(context: *anyopaque, picker: *QuickPick) !void {
    const w: *Workbench = @ptrCast(@alignCast(context));
    const value = std.mem.trim(u8, picker.value.items, " \t");
    const port = std.fmt.parseUnsigned(u16, value, 10) catch 0;
    if (port == 0) {
        w.setStatusHint("Enter a port between 1 and 65535", .{});
        return;
    }
    if (w.terminal_service) |service| {
        for (0..service.instanceCount()) |i| {
            const terminal = service.instanceAt(i).?;
            if (terminal.forwarded_port == port and terminal.process_state == .running) {
                w.setStatusHint("Port {d} already has a forwarding terminal", .{port});
                return;
            }
        }
    }
    const executable = try @import("../../vs/platform/terminal/node/terminalProfiles.zig").findTerminalExecutable(w.allocator, w.io, "devtunnel") orelse {
        w.setStatusHint("Install the Microsoft Dev Tunnels CLI and add devtunnel to PATH", .{});
        return;
    };
    defer w.allocator.free(executable);
    var port_buf: [5]u8 = undefined;
    const number = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "Forward Port {d}", .{port});
    const instance = try w.launchTerminalProcess(name, executable, &.{ "host", "-p", number }, null);
    instance.forwarded_port = port;
}

fn chooseTunnel(context: *anyopaque) !void {
    const w: *Workbench = @ptrCast(@alignCast(context));
    const arena = w.navigation_arena.allocator();
    var items: std.ArrayList(Item) = .empty;
    if (w.terminal_service) |service| {
        for (0..service.instanceCount()) |i| {
            const terminal = service.instanceAt(i).?;
            const port = terminal.forwarded_port orelse continue;
            if (terminal.process_state != .running) continue;
            try items.append(arena, .{ .item = .{
                .id = try std.fmt.allocPrint(arena, "{d}", .{terminal.id}),
                .label = try std.fmt.allocPrint(arena, "Port {d}", .{port}),
            } });
        }
    }
    try w.quick_access.inputService().showPick(items.items, .{ .placeholder = "Select a port to stop forwarding", .no_results_label = "No forwarded ports" }, stop, w);
}

fn stop(context: *anyopaque, picker: *QuickPick) !void {
    const w: *Workbench = @ptrCast(@alignCast(context));
    const item = picker.selectedItem() orelse return;
    const id = std.fmt.parseUnsigned(usize, item.id, 10) catch return;
    const service = w.terminal_service orelse return;
    for (0..service.instanceCount()) |i| {
        const terminal = service.instanceAt(i).?;
        if (terminal.id == id and terminal.forwarded_port != null) {
            terminal.writeInput("\x03");
            return;
        }
    }
}
