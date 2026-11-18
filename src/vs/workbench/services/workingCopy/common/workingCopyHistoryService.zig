// Terminal subset of
// `src/vs/workbench/services/workingCopy/common/workingCopyHistoryService.ts`.
//
// History entries are kept in memory (the terminal has no history storage yet)
// and capped per resource; the portable add/list/remove/clear/event behavior is
// ported.
const std = @import("std");
const Allocator = std.mem.Allocator;

const history_mod = @import("./workingCopyHistory.zig");
const Entry = history_mod.WorkingCopyHistoryEntry;
const EntryView = history_mod.WorkingCopyHistoryEntryView;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const WorkingCopyHistoryService = struct {
    allocator: Allocator,
    entries: std.array_list.Managed(Entry),
    max_entries_per_resource: usize,
    on_did_change: Emitter([]const u8),

    pub fn init(allocator: Allocator, max_entries_per_resource: usize) WorkingCopyHistoryService {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(Entry).init(allocator),
            .max_entries_per_resource = max_entries_per_resource,
            .on_did_change = Emitter([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *WorkingCopyHistoryService) void {
        for (self.entries.items) |entry| self.freeEntry(entry);
        self.entries.deinit();
        self.on_did_change.deinit();
    }

    fn freeEntry(self: *WorkingCopyHistoryService, entry: Entry) void {
        self.allocator.free(entry.resource);
        self.allocator.free(entry.type_id);
        self.allocator.free(entry.content);
    }

    pub fn addEntry(self: *WorkingCopyHistoryService, resource: []const u8, type_id: []const u8, timestamp: i64, content: []const u8) !void {
        const entry = Entry{
            .resource = try self.allocator.dupe(u8, resource),
            .type_id = try self.allocator.dupe(u8, type_id),
            .timestamp = timestamp,
            .content = try self.allocator.dupe(u8, content),
        };
        errdefer self.freeEntry(entry);
        try self.entries.insert(0, entry);

        var count: usize = 0;
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const current = self.entries.items[index];
            if (std.mem.eql(u8, current.resource, resource) and std.mem.eql(u8, current.type_id, type_id)) {
                count += 1;
                if (count > self.max_entries_per_resource) {
                    const removed = self.entries.orderedRemove(index);
                    self.freeEntry(removed);
                    continue;
                }
            }
            index += 1;
        }
        try self.on_did_change.fire(resource);
    }

    /// Returns matching entries newest-first; the caller frees the slice only.
    pub fn getEntries(self: *const WorkingCopyHistoryService, resource: []const u8, allocator: Allocator) ![]EntryView {
        var result = std.array_list.Managed(EntryView).init(allocator);
        defer result.deinit();
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.resource, resource)) continue;
            try result.append(.{
                .resource = entry.resource,
                .type_id = entry.type_id,
                .timestamp = entry.timestamp,
                .content = entry.content,
            });
        }
        return result.toOwnedSlice();
    }

    pub fn entryCount(self: *const WorkingCopyHistoryService) usize {
        return self.entries.items.len;
    }

    pub fn removeEntry(self: *WorkingCopyHistoryService, resource: []const u8, type_id: []const u8, timestamp: i64) bool {
        var index: usize = 0;
        while (index < self.entries.items.len) : (index += 1) {
            const entry = self.entries.items[index];
            if (std.mem.eql(u8, entry.resource, resource) and
                std.mem.eql(u8, entry.type_id, type_id) and
                entry.timestamp == timestamp)
            {
                const removed = self.entries.orderedRemove(index);
                self.freeEntry(removed);
                self.on_did_change.fire(resource) catch {};
                return true;
            }
        }
        return false;
    }

    pub fn clear(self: *WorkingCopyHistoryService, resource: ?[]const u8) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (resource == null or std.mem.eql(u8, entry.resource, resource.?)) {
                const removed = self.entries.orderedRemove(index);
                self.freeEntry(removed);
                continue;
            }
            index += 1;
        }
        self.on_did_change.fire(resource orelse "") catch {};
    }
};
