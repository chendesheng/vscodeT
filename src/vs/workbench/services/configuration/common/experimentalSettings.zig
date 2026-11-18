// Port of `src/vs/workbench/services/configuration/common/experimentalSettings.ts`.
//
// Terminal adaptation: the upstream `RunOnceScheduler` uses a timer; the
// terminal scheduler is polled by the host (`poll(now_ms)` in the tests), so
// assignment changes are still coalesced into one notification per batch.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const async_mod = @import("../../../../base/common/async.zig");
const RunOnceScheduler = async_mod.RunOnceScheduler;

pub const ExperimentalSettingsService = struct {
    allocator: Allocator,
    assignments: std.StringHashMap(void),
    requested_keys: std.StringHashMap(std.array_list.Managed([]u8)),
    pending_changes: std.array_list.Managed([]u8),
    on_did_change_assignments: Emitter([]const []const u8),
    on_did_request_keys: Emitter([]const u8),
    change_scheduler: RunOnceScheduler(*ExperimentalSettingsService),

    pub fn init(self: *ExperimentalSettingsService, allocator: Allocator) void {
        self.* = .{
            .allocator = allocator,
            .assignments = std.StringHashMap(void).init(allocator),
            .requested_keys = std.StringHashMap(std.array_list.Managed([]u8)).init(allocator),
            .pending_changes = std.array_list.Managed([]u8).init(allocator),
            .on_did_change_assignments = Emitter([]const []const u8).init(allocator),
            .on_did_request_keys = Emitter([]const u8).init(allocator),
            .change_scheduler = undefined,
        };
        self.change_scheduler = RunOnceScheduler(*ExperimentalSettingsService).init(self, firePendingChanges, 0);
    }

    pub fn deinit(self: *ExperimentalSettingsService) void {
        self.change_scheduler.cancel();
        var assignment_iterator = self.assignments.keyIterator();
        while (assignment_iterator.next()) |key| self.allocator.free(key.*);
        self.assignments.deinit();
        var requested_iterator = self.requested_keys.iterator();
        while (requested_iterator.next()) |entry| {
            for (entry.value_ptr.items) |key| self.allocator.free(key);
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.requested_keys.deinit();
        for (self.pending_changes.items) |key| self.allocator.free(key);
        self.pending_changes.deinit();
        self.on_did_change_assignments.deinit();
        self.on_did_request_keys.deinit();
    }

    pub fn listenAssignments(self: *ExperimentalSettingsService, context: anytype, callback: fn ([]const []const u8, @TypeOf(context)) anyerror!void) !usize {
        return self.on_did_change_assignments.listen(context, callback);
    }

    pub fn listenRequestKeys(self: *ExperimentalSettingsService, context: anytype, callback: fn ([]const u8, @TypeOf(context)) anyerror!void) !usize {
        return self.on_did_request_keys.listen(context, callback);
    }

    pub fn hasAssignment(self: *const ExperimentalSettingsService, setting: []const u8) bool {
        return self.assignments.contains(setting);
    }

    pub fn setAssignment(self: *ExperimentalSettingsService, setting: []const u8, assigned: bool) !void {
        const currently_assigned = self.assignments.contains(setting);
        if (currently_assigned == assigned) return;
        if (assigned) {
            try self.assignments.put(try self.allocator.dupe(u8, setting), {});
        } else {
            if (self.assignments.fetchRemove(setting)) |removed| self.allocator.free(removed.key);
        }
        var already_pending = false;
        for (self.pending_changes.items) |pending| {
            if (std.mem.eql(u8, pending, setting)) {
                already_pending = true;
                break;
            }
        }
        if (!already_pending) try self.pending_changes.append(try self.allocator.dupe(u8, setting));
        if (!self.change_scheduler.isScheduled()) self.change_scheduler.schedule(0, 0);
    }

    pub fn requestKeys(self: *ExperimentalSettingsService, setting: []const u8, keys: []const []const u8) !void {
        const entry = try self.requested_keys.getOrPut(setting);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, setting);
            entry.value_ptr.* = std.array_list.Managed([]u8).init(self.allocator);
        }
        const size = entry.value_ptr.items.len;
        for (keys) |key| {
            var present = false;
            for (entry.value_ptr.items) |existing| {
                if (std.mem.eql(u8, existing, key)) {
                    present = true;
                    break;
                }
            }
            if (!present) try entry.value_ptr.append(try self.allocator.dupe(u8, key));
        }
        if (entry.value_ptr.items.len != size) try self.on_did_request_keys.fire(setting);
    }

    pub fn getRequestedKeys(self: *const ExperimentalSettingsService, setting: []const u8) []const []u8 {
        if (self.requested_keys.get(setting)) |keys| return keys.items;
        return &.{};
    }

    /// Flushes the batched assignment notification once its zero-delay
    /// scheduler deadline has passed.
    pub fn poll(self: *ExperimentalSettingsService, now_ms: i64) bool {
        return self.change_scheduler.poll(now_ms);
    }

    fn firePendingChanges(self: *ExperimentalSettingsService) void {
        if (self.pending_changes.items.len == 0) return;
        const changes = self.pending_changes.toOwnedSlice() catch return;
        defer {
            for (changes) |key| self.allocator.free(key);
            self.allocator.free(changes);
        }
        self.pending_changes = std.array_list.Managed([]u8).init(self.allocator);
        self.on_did_change_assignments.fire(changes) catch {};
    }
};
