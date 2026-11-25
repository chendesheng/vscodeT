// Port of the explicit request/accept flow from
// src/vs/workbench/contrib/terminalContrib/suggest/browser/terminalSuggestAddon.ts.
// The terminal backend supplies prompt cells through the cursor and can safely
// append a suffix. The terminal quick picker presents those completions.
const std = @import("std");
const api = @import("terminalCompletionService.zig");
const TerminalInstance = @import("../../../terminal/browser/terminalInstance.zig").TerminalInstance;
const CommandRegistry = @import("../../../../browser/commands.zig").CommandRegistry;
const QuickAccessService = @import("../../../../browser/quickaccess.zig").QuickAccessService;
const positions = @import("../../../../api/common/positionConverter.zig");
const QuickPick = @import("../../../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const Item = @import("../../../../../platform/quickinput/common/quickInput.zig").QuickPickItem;

pub const command = "workbench.action.terminal.requestCompletions";

pub const TerminalHost = struct {
    context: *anyopaque,
    focused: *const fn (*anyopaque) ?*TerminalInstance,
    find: *const fn (*anyopaque, usize) ?*TerminalInstance,
    request_render: *const fn (*anyopaque) void,
};

pub const TerminalSuggestAddon = struct {
    host: TerminalHost,
    service: api.ITerminalCompletionService,
    commands: *CommandRegistry,
    quick_access: *QuickAccessService,
    arena: std.heap.ArenaAllocator,
    terminal: ?usize = null,
    line: []const u8 = "",

    pub fn init(self: *TerminalSuggestAddon, allocator: std.mem.Allocator, host: TerminalHost, service: api.ITerminalCompletionService, commands: *CommandRegistry, quick_access: *QuickAccessService) !void {
        self.* = .{ .host = host, .service = service, .commands = commands, .quick_access = quick_access, .arena = .init(allocator) };
        try commands.register(.{ .id = command, .label = "Request Completions", .category = "Terminal", .context = self, .run = request });
    }

    pub fn deinit(self: *TerminalSuggestAddon) void {
        self.service.cancel();
        const picker = self.quick_access.inputService();
        if (picker.handler_context == @as(*anyopaque, @ptrCast(self))) picker.hide();
        if (self.commands.get(command)) |info| {
            if (info.context == @as(*anyopaque, @ptrCast(self))) self.commands.unregister(command);
        }
        self.arena.deinit();
    }

    fn request(context: *anyopaque) !void {
        const self: *TerminalSuggestAddon = @ptrCast(@alignCast(context));
        try self.requestCompletions();
    }

    pub fn requestCompletions(self: *TerminalSuggestAddon) !void {
        const instance = self.host.focused(self.host.context) orelse return;
        // Visible picker rows borrow the arena until the picker is closed.
        if (self.quick_access.isOpen()) return;
        self.service.cancel();
        _ = self.arena.reset(.retain_capacity);
        self.line = try instance.emulator.promptInput(self.arena.allocator()) orelse return;
        self.terminal = instance.id;
        const cursor = positions.utf16OffsetForColumn(self.line, self.line.len + 1) - 1;
        try self.service.provideCompletions(instance, self.line, cursor, .{ .context = self, .accept = receive });
    }

    fn receive(context: *anyopaque, entries: []const api.Completion) void {
        const self: *TerminalSuggestAddon = @ptrCast(@alignCast(context));
        self.show(entries) catch {};
    }

    fn show(self: *TerminalSuggestAddon, entries: []const api.Completion) !void {
        const instance = self.host.focused(self.host.context) orelse return;
        if (instance.id != self.terminal or self.quick_access.isOpen()) return;
        const arena = self.arena.allocator();
        const current = try instance.emulator.promptInput(arena) orelse return;
        if (!std.mem.eql(u8, current, self.line)) return;
        const items = try completionItems(arena, self.line, entries);
        if (items.len == 0) return;
        try self.quick_access.inputService().showPick(items, .{ .placeholder = "Select a terminal suggestion" }, accept, self);
        self.host.request_render(self.host.context);
    }

    fn accept(context: *anyopaque, picker: *QuickPick) !void {
        const self: *TerminalSuggestAddon = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse return;
        const instance = self.host.find(self.host.context, self.terminal orelse return) orelse return;
        const line = try instance.emulator.promptInput(self.arena.allocator()) orelse return;
        if (std.mem.eql(u8, line, self.line)) instance.writeInput(item.id);
    }
};

fn completionItems(arena: std.mem.Allocator, line: []const u8, entries: []const api.Completion) ![]const Item {
    var items: std.ArrayList(Item) = .empty;
    const end = positions.utf16OffsetForColumn(line, line.len + 1) - 1;
    for (entries) |entry| {
        const start, const stop = entry.replacement_range;
        if (stop != end or start > stop) continue;
        const column = positions.columnForUtf16Offset(line, start + 1);
        if (positions.utf16OffsetForColumn(line, column) != start + 1) continue;
        const prefix = line[column - 1 ..];
        if (!std.mem.startsWith(u8, entry.label, prefix) or entry.label.len == prefix.len) continue;
        for (entry.label) |c| {
            if (c < 32 or c == 127) break;
        } else {
            const label = try arena.dupe(u8, entry.label);
            try items.append(arena, .{ .item = .{ .id = label[prefix.len..], .label = label } });
        }
    }
    return items.items;
}

test "terminal suggestion replacement ranges use UTF-16 and only append text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const items = try completionItems(arena.allocator(), "x😀a", &.{
        .{ .label = "abc", .replacement_range = .{ 3, 4 } },
        .{ .label = "a", .replacement_range = .{ 3, 4 } },
        .{ .label = "a\n", .replacement_range = .{ 3, 4 } },
        .{ .label = "abc", .replacement_range = .{ 2, 4 } },
        .{ .label = "abc", .replacement_range = .{ 3, 5 } },
    });
    try std.testing.expectEqual(1, items.len);
    try std.testing.expectEqualStrings("bc", items[0].item.id);
}
