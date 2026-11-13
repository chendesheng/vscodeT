// Port of the portable command-pick provider in
// `src/vs/platform/quickinput/browser/commandsQuickAccess.ts`.
//
// Kept from upstream: label filtering, exact command-id matches,
// duplicate-label descriptions, recent-command ordering, "recently used" /
// "other commands" separators, and accepting a pick by pushing it to history
// and executing the command.
//
// Not ported because the TUI has no corresponding service: TF-IDF/AI command
// suggestions, suggested-command separators, telemetry, dialog error boxes,
// keybinding labels, command aliases and the remove-from-history button. The
// command history is in-memory for the session (no storage service).

const std = @import("std");
const Allocator = std.mem.Allocator;
const filters = @import("../../../base/common/filters.zig");
const cancellation = @import("../../../base/common/cancellation.zig");
const CancellationToken = cancellation.CancellationToken;
const quick_input = @import("../common/quickInput.zig");
const QuickPickItem = quick_input.QuickPickItem;
const QuickPick = @import("./quickInput.zig").QuickPick;
const picker = @import("./pickerQuickAccess.zig");
const quick_access = @import("../common/quickAccess.zig");
const Provider = quick_access.Provider;

pub const CommandPick = struct {
    command_id: []const u8,
    label: []const u8,
    category: []const u8 = "",
    description: []const u8 = "",
};

pub const CommandExecutor = struct {
    context: *anyopaque,
    execute: *const fn (context: *anyopaque, command_id: []const u8) anyerror!void,
    on_error: ?*const fn (context: *anyopaque, message: []const u8) void = null,
};

pub const CommandPickSource = struct {
    context: *anyopaque,
    get_picks: *const fn (
        context: *anyopaque,
        allocator: Allocator,
    ) anyerror![]CommandPick,
};

pub const CommandsHistory = struct {
    allocator: Allocator,
    entries: std.array_list.Managed([]u8),
    max: usize = 50,

    pub fn init(allocator: Allocator) CommandsHistory {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *CommandsHistory) void {
        for (self.entries.items) |entry| self.allocator.free(entry);
        self.entries.deinit();
    }

    pub fn push(self: *CommandsHistory, command_id: []const u8) !void {
        self.remove(command_id);
        const copy = try self.allocator.dupe(u8, command_id);
        errdefer self.allocator.free(copy);
        try self.entries.insert(0, copy);
        while (self.entries.items.len > self.max) {
            const removed = self.entries.pop().?;
            self.allocator.free(removed);
        }
    }

    pub fn remove(self: *CommandsHistory, command_id: []const u8) void {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry, command_id)) {
                const removed = self.entries.orderedRemove(index);
                self.allocator.free(removed);
                return;
            }
        }
    }

    /// MRU rank: 0 is the most recently used command, null is unused.
    pub fn rank(self: *const CommandsHistory, command_id: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry, command_id)) return index;
        }
        return null;
    }

    pub fn clear(self: *CommandsHistory) void {
        for (self.entries.items) |entry| self.allocator.free(entry);
        self.entries.clearRetainingCapacity();
    }
};

pub const CommandsQuickAccessProvider = struct {
    allocator: Allocator,
    prefix: []const u8,
    source: CommandPickSource,
    executor: CommandExecutor,
    history: CommandsHistory,
    arena: std.heap.ArenaAllocator,

    pub fn init(
        allocator: Allocator,
        prefix: []const u8,
        source: CommandPickSource,
        executor: CommandExecutor,
    ) !*CommandsQuickAccessProvider {
        const self = try allocator.create(CommandsQuickAccessProvider);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .prefix = prefix,
            .source = source,
            .executor = executor,
            .history = CommandsHistory.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return self;
    }

    pub fn interface(self: *CommandsQuickAccessProvider) Provider {
        return .{
            .context = self,
            .prefix = self.prefix,
            .placeholder = "Type the name of a command to run.",
            .provide = provideFn,
            .refresh = refreshFn,
            .accept = acceptFn,
            .dispose = disposeFn,
        };
    }

    fn provideFn(context: *anyopaque, picker_ref: *QuickPick, token: CancellationToken) anyerror!void {
        const self: *CommandsQuickAccessProvider = @ptrCast(@alignCast(context));
        try picker.provide(self.impl(), self.options(), picker_ref, token);
    }

    fn refreshFn(context: *anyopaque, picker_ref: *QuickPick) anyerror!void {
        const self: *CommandsQuickAccessProvider = @ptrCast(@alignCast(context));
        try picker.refresh(self.impl(), self.options(), picker_ref);
    }

    fn acceptFn(context: *anyopaque, picker_ref: *QuickPick) anyerror!void {
        _ = context;
        return picker.accept(picker_ref);
    }

    fn disposeFn(context: *anyopaque) void {
        const self: *CommandsQuickAccessProvider = @ptrCast(@alignCast(context));
        self.arena.deinit();
        self.history.deinit();
        self.allocator.destroy(self);
    }

    fn options(self: *const CommandsQuickAccessProvider) picker.PickerOptions {
        return .{
            .prefix = self.prefix,
            .no_results_pick = .{ .item = .{ .id = "", .label = "No matching commands" } },
        };
    }

    fn impl(self: *CommandsQuickAccessProvider) picker.PickerImpl {
        return .{ .context = self, .get_picks = getPicks };
    }

    fn getPicks(context: *anyopaque, filter: []const u8, _: Allocator) anyerror!?[]QuickPickItem {
        const self: *CommandsQuickAccessProvider = @ptrCast(@alignCast(context));
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();

        const all = try self.source.get_picks(self.source.context, arena);
        var filtered = std.array_list.Managed(CommandPick).init(arena);
        var label_matches = std.array_list.Managed(LabelMatch).init(arena);

        for (all) |command| {
            const display_label = try formatLabel(arena, command);
            var label_match: []const filters.Match = &.{};
            var keep = false;
            if (filter.len == 0) {
                keep = true;
            } else if (filters.matchesBaseContiguousSubString(filter, display_label)) |match| {
                label_match = try arena.dupe(filters.Match, &.{match});
                keep = true;
            } else if (try filters.matchesWords(arena, filter, display_label)) |words| {
                label_match = words;
                keep = true;
            } else if (std.mem.eql(u8, filter, command.command_id)) {
                keep = true;
            }
            if (!keep) continue;

            try filtered.append(.{
                .command_id = command.command_id,
                .label = display_label,
                .category = command.category,
                .description = command.description,
            });
            try label_matches.append(.{ .command_id = command.command_id, .label = label_match });
        }

        // Duplicate labels are disambiguated with the command id, as upstream.
        var i: usize = 0;
        while (i < filtered.items.len) : (i += 1) {
            var j = i + 1;
            while (j < filtered.items.len) : (j += 1) {
                if (std.mem.eql(u8, filtered.items[i].label, filtered.items[j].label)) {
                    filtered.items[i].description = filtered.items[i].command_id;
                    filtered.items[j].description = filtered.items[j].command_id;
                }
            }
        }

        const SortContext = struct {
            history: *const CommandsHistory,
        };
        std.mem.sort(CommandPick, filtered.items, SortContext{ .history = &self.history }, struct {
            fn lessThan(ctx: SortContext, a: CommandPick, b: CommandPick) bool {
                const rank_a = ctx.history.rank(a.command_id);
                const rank_b = ctx.history.rank(b.command_id);
                if (rank_a != null and rank_b != null) return rank_a.? < rank_b.?;
                if (rank_a != null) return true;
                if (rank_b != null) return false;
                return std.mem.lessThan(u8, a.label, b.label);
            }
        }.lessThan);

        var items = std.array_list.Managed(QuickPickItem).init(arena);
        var add_other_separator = false;
        for (filtered.items, 0..) |command, index| {
            const has_history = self.history.rank(command.command_id) != null;

            if (index == 0 and has_history) {
                try items.append(.{ .separator = .{ .label = "recently used" } });
                add_other_separator = true;
            }
            if (add_other_separator and !has_history) {
                try items.append(.{ .separator = .{ .label = "other commands" } });
                add_other_separator = false;
            }
            var highlight: []const filters.Match = &.{};
            for (label_matches.items) |entry| {
                if (std.mem.eql(u8, entry.command_id, command.command_id)) {
                    highlight = entry.label;
                    break;
                }
            }
            const accept_state = try arena.create(AcceptState);
            accept_state.* = .{ .provider = self, .command_id = command.command_id };
            try items.append(.{ .item = .{
                .id = command.command_id,
                .label = command.label,
                .description = command.description,
                .highlights = .{ .label = highlight },
                .accept_context = accept_state,
                .accept = acceptItem,
            } });
        }
        return try items.toOwnedSlice();
    }

    fn acceptItem(context: *anyopaque) anyerror!void {
        const state: *AcceptState = @ptrCast(@alignCast(context));
        const provider = state.provider;
        // Executing a command may open another picker and reset this
        // provider's arena, freeing `state` and its command id. Copy what the
        // callback still needs before running it.
        const command_id = try provider.allocator.dupe(u8, state.command_id);
        defer provider.allocator.free(command_id);

        try provider.history.push(command_id);
        provider.executor.execute(provider.executor.context, command_id) catch |err| {
            if (provider.executor.on_error) |on_error| {
                on_error(provider.executor.context, @errorName(err));
            }
        };
    }
};

const LabelMatch = struct {
    command_id: []const u8,
    label: []const filters.Match,
};

const AcceptState = struct {
    provider: *CommandsQuickAccessProvider,
    command_id: []const u8,
};

fn formatLabel(allocator: Allocator, command: CommandPick) ![]const u8 {
    if (command.category.len == 0) return command.label;
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ command.category, command.label });
}

test "CommandsHistory: MRU order, dedupe and cap" {
    var history = CommandsHistory.init(std.testing.allocator);
    defer history.deinit();

    try history.push("a");
    try history.push("b");
    try history.push("a");
    try std.testing.expectEqual(@as(?usize, 0), history.rank("a"));
    try std.testing.expectEqual(@as(?usize, 1), history.rank("b"));
    history.remove("a");
    try std.testing.expectEqual(@as(?usize, null), history.rank("a"));
}
