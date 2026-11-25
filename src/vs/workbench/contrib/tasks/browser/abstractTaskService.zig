// Port of provider registration and contributed task selection from
// `src/vs/workbench/contrib/tasks/browser/abstractTaskService.ts`.
// The terminal host executes the selected process or shell task in its PTY.
const std = @import("std");
const contracts = @import("../common/taskService.zig");
const manager = @import("../../../services/extensions/common/extensionHostManager.zig");
const CommandRegistry = @import("../../../browser/commands.zig").CommandRegistry;
const QuickInputService = @import("../../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const QuickPick = @import("../../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const Item = @import("../../../../platform/quickinput/common/quickInput.zig").QuickPickItem;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const Allocator = std.mem.Allocator;
const run_command = "workbench.action.tasks.runTask";

pub const Host = struct {
    context: *anyopaque,
    activate: *const fn (*anyopaque, Allocator, []const u8) anyerror!void,
    run_terminal: *const fn (*anyopaque, []const u8, []const u8, []const []const u8, ?[]const u8) anyerror!void,
};

pub const AbstractTaskService = struct {
    allocator: Allocator,
    commands: *CommandRegistry,
    quick_input: *QuickInputService,
    extensions: []const manager.ExtensionDescription,
    host: Host,
    choices: std.heap.ArenaAllocator,
    tasks: []const std.json.Value = &.{},
    providers: std.AutoArrayHashMapUnmanaged(usize, Entry) = .empty,
    on_did_change_task_providers: Emitter(void),
    next_handle: usize = 0,

    const Entry = struct { kind: []const u8, provider: contracts.ITaskProvider };
    const Registration = struct {
        service: *AbstractTaskService,
        handle: usize,

        fn dispose(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const service = self.service;
            const entry = service.providers.fetchOrderedRemove(self.handle).?;
            service.allocator.free(entry.value.kind);
            service.allocator.destroy(self);
            service.on_did_change_task_providers.fire({}) catch {};
        }
    };

    pub fn init(self: *@This(), allocator: Allocator, commands: *CommandRegistry, input: *QuickInputService, extensions: []const manager.ExtensionDescription, host: Host) !void {
        self.* = .{
            .allocator = allocator,
            .commands = commands,
            .quick_input = input,
            .extensions = extensions,
            .host = host,
            .choices = .init(allocator),
            .on_did_change_task_providers = .init(allocator),
        };
        for (extensions) |extension| {
            if (definitions(extension) == null) continue;
            try commands.registerCommand(.{ .id = run_command, .context = self, .run = chooseType }, .{ .id = run_command, .title = "Run Task", .category = "Tasks" }, .{});
            break;
        }
    }

    pub fn deinit(self: *@This()) void {
        if (self.commands.get(run_command)) |command| {
            if (command.context == @as(*anyopaque, @ptrCast(self))) self.commands.unregister(run_command);
        }
        std.debug.assert(self.providers.count() == 0);
        self.providers.deinit(self.allocator);
        self.on_did_change_task_providers.deinit();
        self.choices.deinit();
    }

    pub fn interface(self: *@This()) contracts.ITaskService {
        return .{ .context = self, .register_task_provider = registerTaskProvider };
    }

    fn registerTaskProvider(context: *anyopaque, provider: contracts.ITaskProvider, kind: []const u8) !IDisposable {
        const self: *@This() = @ptrCast(@alignCast(context));
        const registration = try self.allocator.create(Registration);
        errdefer self.allocator.destroy(registration);
        const owned = try self.allocator.dupe(u8, kind);
        errdefer self.allocator.free(owned);
        const handle = self.next_handle;
        try self.providers.put(self.allocator, handle, .{ .kind = owned, .provider = provider });
        self.next_handle += 1;
        registration.* = .{ .service = self, .handle = handle };
        self.on_did_change_task_providers.fire({}) catch {};
        return .{ .context = registration, .disposeFn = Registration.dispose };
    }

    fn definitions(extension: manager.ExtensionDescription) ?[]const std.json.Value {
        const contributes = extension.manifest.object.get("contributes") orelse return null;
        if (contributes != .object) return null;
        const defs = contributes.object.get("taskDefinitions") orelse return null;
        return if (defs == .array) defs.array.items else null;
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
        try self.quick_input.showPick(items.items, .{ .placeholder = "Select a task type" }, chooseTask, self);
    }

    fn chooseTask(context: *anyopaque, picker: *QuickPick) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const selection = picker.selectedItem() orelse return;
        const arena = self.choices.allocator();
        const kind = try arena.dupe(u8, selection.id);
        const event = try std.fmt.allocPrint(arena, "onTaskType:{s}", .{kind});
        try self.host.activate(self.host.context, arena, event);
        var types: std.json.ObjectMap = .empty;
        try types.put(arena, kind, .{ .bool = true });
        var items: std.ArrayList(Item) = .empty;
        var tasks: std.ArrayList(std.json.Value) = .empty;
        // Activation and subsequent provider calls can register new handles.
        const handles = try arena.dupe(usize, self.providers.keys());
        for (handles) |handle| {
            const entry = self.providers.get(handle) orelse continue;
            if (!std.mem.eql(u8, kind, entry.kind)) continue;
            const results = try entry.provider.provide_tasks(entry.provider.context, arena, .{ .object = types });
            for (results) |task| {
                const name = string(task, "name") orelse continue;
                const execution = task.object.get("execution") orelse continue;
                if (execution != .object or (!execution.object.contains("command") and !execution.object.contains("commandLine") and !execution.object.contains("process"))) continue;
                const id = try std.fmt.allocPrint(arena, "{d}", .{tasks.items.len});
                try items.append(arena, .{ .item = .{ .id = id, .label = name, .description = string(task, "detail") orelse "" } });
                try tasks.append(arena, task);
            }
        }
        self.tasks = tasks.items;
        try self.quick_input.showPick(items.items, .{ .placeholder = "Select a task to run", .no_results_label = "No tasks found" }, run, self);
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
        try self.host.run_terminal(self.host.context, item.label, executable, argv.items, string(options, "cwd"));
    }

    fn string(value: std.json.Value, key: []const u8) ?[]const u8 {
        if (value != .object) return null;
        const found = value.object.get(key) orelse return null;
        return if (found == .string) found.string else null;
    }
};
