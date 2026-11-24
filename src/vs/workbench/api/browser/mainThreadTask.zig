// Workbench bridge for task type discovery and shell tasks contributed by extensions.
const std = @import("std");
const Workbench = @import("../../browser/workbench.zig").Workbench;
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const protocol = @import("../common/extHost.protocol.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const proxy = @import("../../services/extensions/common/proxyIdentifier.zig").identifierFromEnum;
const QuickPick = @import("../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const Item = @import("../../../platform/quickinput/common/quickInput.zig").QuickPickItem;
const Allocator = std.mem.Allocator;
const run_command = "workbench.action.tasks.runTask";

pub const MainThreadTask = struct {
    workbench: *Workbench,
    host: *manager.HostManager,
    extensions: []const manager.ExtensionDescription,
    providers: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .empty,
    choices: std.heap.ArenaAllocator,
    tasks: []const std.json.Value = &.{},

    pub fn init(self: *@This(), workbench: *Workbench, host: *manager.HostManager, extensions: []const manager.ExtensionDescription) !void {
        self.* = .{ .workbench = workbench, .host = host, .extensions = extensions, .choices = .init(workbench.allocator) };
        for (extensions) |extension| {
            if (definitions(extension) == null) continue;
            try workbench.commands.register(.{ .id = run_command, .label = "Run Task", .category = "Tasks", .context = self, .run = chooseType });
            break;
        }
    }

    pub fn deinit(self: *@This()) void {
        if (self.workbench.commands.get(run_command)) |command| {
            if (command.context == @as(*anyopaque, @ptrCast(self))) self.workbench.commands.unregister(run_command);
        }
        for (self.providers.values()) |kind| self.workbench.allocator.free(kind);
        self.providers.deinit(self.workbench.allocator);
        self.choices.deinit();
    }

    fn definitions(extension: manager.ExtensionDescription) ?[]const std.json.Value {
        const contributes = extension.manifest.object.get("contributes") orelse return null;
        if (contributes != .object) return null;
        const defs = contributes.object.get("taskDefinitions") orelse return null;
        return if (defs == .array) defs.array.items else null;
    }

    pub fn invoke(self: *@This(), method: []const u8, args: []const rpc.Arg) !rpc.HandlerReply {
        const register = std.mem.eql(u8, method, "$registerTaskProvider");
        if (register or std.mem.eql(u8, method, "$unregisterTaskProvider")) {
            if (args.len < 1 or args[0] != .json or args[0].json != .integer) return error.InvalidArguments;
            const handle = std.math.cast(u32, args[0].json.integer) orelse return error.InvalidArguments;
            const allocator = self.workbench.allocator;
            if (register) {
                if (args.len < 2 or args[1] != .json or args[1].json != .string) return error.InvalidArguments;
                const kind = try allocator.dupe(u8, args[1].json.string);
                errdefer allocator.free(kind);
                if (try self.providers.fetchPut(allocator, handle, kind)) |old| allocator.free(old.value);
            } else if (self.providers.fetchOrderedRemove(handle)) |old| allocator.free(old.value);
        } else if (!std.mem.eql(u8, method, "$registerTaskSystem") and !std.mem.eql(u8, method, "$registerSupportedExecutions")) {
            return .{ .err = .{ .name = "Unsupported", .message = method } };
        }
        return .empty;
    }

    fn chooseType(context: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = self.choices.reset(.retain_capacity);
        self.tasks = &.{};
        const arena = self.choices.allocator();
        var items: std.ArrayList(Item) = .empty;
        for (self.extensions) |extension| {
            for (definitions(extension) orelse continue) |definition| {
                const kind = string(definition, "type") orelse continue;
                try items.append(arena, .{ .item = .{ .id = kind, .label = kind } });
            }
        }
        try self.workbench.quick_access.inputService().showPick(items.items, .{ .placeholder = "Select a task type" }, chooseTask, self);
    }

    fn chooseTask(context: *anyopaque, picker: *QuickPick) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const selection = picker.selectedItem() orelse return;
        const arena = self.choices.allocator();
        const kind = try arena.dupe(u8, selection.id);
        const event = try std.fmt.allocPrint(arena, "onTaskType:{s}", .{kind});
        _ = try self.host.requestSync(arena, proxy(protocol.ExtHostContext.ExtHostExtensionService), "$activateByEvent", &.{ .{ .json = .{ .string = event } }, .{ .json = .{ .integer = 0 } } }, null, 5000);
        var types: std.json.ObjectMap = .empty;
        try types.put(arena, kind, .{ .bool = true });
        var items: std.ArrayList(Item) = .empty;
        var tasks: std.ArrayList(std.json.Value) = .empty;
        // Activation and subsequent provider calls can register new handles.
        const handles = try arena.dupe(u32, self.providers.keys());
        for (handles) |handle| {
            if (!std.mem.eql(u8, kind, self.providers.get(handle) orelse continue)) continue;
            const list = try self.host.requestSync(arena, proxy(protocol.ExtHostContext.ExtHostTask), "$provideTasks", &.{ .{ .json = .{ .integer = handle } }, .{ .json = .{ .object = types } } }, .None, 10000);
            if (list != .object) continue;
            const results = list.object.get("tasks") orelse continue;
            if (results != .array) continue;
            for (results.array.items) |task| {
                const name = string(task, "name") orelse continue;
                const execution = task.object.get("execution") orelse continue;
                if (execution != .object or (!execution.object.contains("command") and !execution.object.contains("commandLine") and !execution.object.contains("process"))) continue;
                const id = try std.fmt.allocPrint(arena, "{d}", .{tasks.items.len});
                try items.append(arena, .{ .item = .{ .id = id, .label = name, .description = string(task, "detail") orelse "" } });
                try tasks.append(arena, task);
            }
        }
        self.tasks = tasks.items;
        try self.workbench.quick_access.inputService().showPick(items.items, .{ .placeholder = "Select a task to run", .no_results_label = "No tasks found" }, run, self);
    }

    fn run(context: *anyopaque, picker: *QuickPick) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse return;
        const index = std.fmt.parseInt(usize, item.id, 10) catch return;
        if (index >= self.tasks.len) return;
        const task = self.tasks[index];
        const execution = task.object.get("execution").?;
        const options = execution.object.get("options") orelse std.json.Value.null;
        const arena = self.choices.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        const executable = if (string(execution, "commandLine")) |cmd| blk: {
            try argv.appendSlice(arena, &.{ "-c", cmd });
            break :blk "/bin/sh";
        } else blk: {
            const program = string(execution, "process") orelse string(execution, "command") orelse return error.UnsupportedTask;
            try argv.appendSlice(arena, &.{ "--", program });
            if (execution.object.get("args")) |args| {
                if (args != .array) return error.UnsupportedTask;
                for (args.array.items) |arg| try argv.append(arena, if (arg == .string) arg.string else string(arg, "value") orelse return error.UnsupportedTask);
            }
            break :blk "/usr/bin/env";
        };
        try self.workbench.runTaskInTerminal(item.label, executable, argv.items, string(options, "cwd"));
    }

    fn string(value: std.json.Value, key: []const u8) ?[]const u8 {
        if (value != .object) return null;
        const found = value.object.get(key) orelse return null;
        return if (found == .string) found.string else null;
    }
};
