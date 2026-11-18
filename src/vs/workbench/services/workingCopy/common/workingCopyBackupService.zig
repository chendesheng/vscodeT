// Terminal subset of
// `src/vs/workbench/services/workingCopy/common/workingCopyBackupService.ts`.
//
// Backups are stored in memory (the terminal has no backup disk service yet);
// the registry, replacement, discard, resource deletion and change event match
// the portable upstream subset.
const std = @import("std");
const Allocator = std.mem.Allocator;

const backup_mod = @import("./workingCopyBackup.zig");
const WorkingCopyBackup = backup_mod.WorkingCopyBackup;
const WorkingCopyBackupIdentifier = backup_mod.WorkingCopyBackupIdentifier;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const WorkingCopyBackupService = struct {
    allocator: Allocator,
    entries: std.StringHashMap(Entry),
    on_did_change_backup: Emitter([]const u8),

    const Entry = struct {
        identifier: WorkingCopyBackupIdentifier,
        content: []u8,
        meta: ?[]u8,
    };

    pub fn init(allocator: Allocator) WorkingCopyBackupService {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(Entry).init(allocator),
            .on_did_change_backup = Emitter([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *WorkingCopyBackupService) void {
        self.clear();
        self.entries.deinit();
        self.on_did_change_backup.deinit();
    }

    fn clear(self: *WorkingCopyBackupService) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.content);
            if (entry.value_ptr.meta) |meta| self.allocator.free(meta);
            self.allocator.free(entry.value_ptr.identifier.resource);
            self.allocator.free(entry.value_ptr.identifier.type_id);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    fn makeKey(allocator: Allocator, identifier: WorkingCopyBackupIdentifier) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ identifier.type_id, identifier.resource });
    }

    pub fn backup(self: *WorkingCopyBackupService, identifier: WorkingCopyBackupIdentifier, content: []const u8, meta: ?[]const u8) !void {
        const key = try makeKey(self.allocator, identifier);
        if (self.entries.fetchRemove(key)) |old| {
            self.freeEntry(old.value);
            self.allocator.free(old.key);
        }
        self.allocator.free(key);
        const entry = Entry{
            .identifier = .{
                .resource = try self.allocator.dupe(u8, identifier.resource),
                .type_id = try self.allocator.dupe(u8, identifier.type_id),
            },
            .content = try self.allocator.dupe(u8, content),
            .meta = if (meta) |value| try self.allocator.dupe(u8, value) else null,
        };
        errdefer self.freeEntry(entry);
        try self.entries.put(try makeKey(self.allocator, identifier), entry);
        try self.on_did_change_backup.fire(identifier.resource);
    }

    fn freeEntry(self: *WorkingCopyBackupService, entry: Entry) void {
        self.allocator.free(entry.identifier.resource);
        self.allocator.free(entry.identifier.type_id);
        self.allocator.free(entry.content);
        if (entry.meta) |meta| self.allocator.free(meta);
    }

    pub fn getBackup(self: *const WorkingCopyBackupService, identifier: WorkingCopyBackupIdentifier) ?WorkingCopyBackup {
        const key = makeKey(self.allocator, identifier) catch return null;
        defer self.allocator.free(key);
        const entry = self.entries.get(key) orelse return null;
        return .{ .content = entry.content, .meta = entry.meta };
    }

    pub fn hasBackup(self: *const WorkingCopyBackupService, identifier: WorkingCopyBackupIdentifier) bool {
        return self.getBackup(identifier) != null;
    }

    pub fn discardBackup(self: *WorkingCopyBackupService, identifier: WorkingCopyBackupIdentifier) void {
        const key = makeKey(self.allocator, identifier) catch return;
        defer self.allocator.free(key);
        if (self.entries.fetchRemove(key)) |removed| {
            self.freeEntry(removed.value);
            self.allocator.free(removed.key);
            self.on_did_change_backup.fire(identifier.resource) catch {};
        }
    }

    pub fn deleteBackups(self: *WorkingCopyBackupService, resource: []const u8) void {
        var keys = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (keys.items) |key| self.allocator.free(key);
            keys.deinit();
        }
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.identifier.resource, resource)) {
                keys.append(self.allocator.dupe(u8, entry.key_ptr.*) catch continue) catch continue;
            }
        }
        for (keys.items) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                self.freeEntry(removed.value);
                self.allocator.free(removed.key);
            }
        }
        if (keys.items.len > 0) self.on_did_change_backup.fire(resource) catch {};
    }

    pub fn backupCount(self: *const WorkingCopyBackupService) usize {
        return self.entries.count();
    }
};
