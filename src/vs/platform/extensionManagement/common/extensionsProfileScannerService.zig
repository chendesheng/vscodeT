// Port of the default-profile selection file in
// `src/vs/platform/extensionManagement/common/extensionsProfileScannerService.ts`.
// Preserve unknown metadata when updating a single identifier. The terminal
// still scans the package directory for manifests; the profile determines
// which version/location is selected, including an explicit downgrade.
const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("extensionManagementUtil.zig");
const storage = @import("../../storage/common/storage.zig");

pub const Profile = struct {
    allocator: Allocator,
    arena: *std.heap.ArenaAllocator,
    entries: std.json.Array,
    exists: bool,
    path: []const u8,

    pub fn load(allocator: Allocator, io: std.Io, location: []const u8) !Profile {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const scratch = arena.allocator();
        const path = try std.fs.path.join(scratch, &.{ location, "extensions.json" });
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, scratch, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return .{ .allocator = allocator, .arena = arena, .entries = .init(scratch), .exists = false, .path = path },
            else => return err,
        };
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, scratch, raw, .{});
        if (parsed != .array) return error.InvalidExtensionsProfile;
        return .{ .allocator = allocator, .arena = arena, .entries = parsed.array, .exists = true, .path = path };
    }

    pub fn deinit(self: *Profile) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    fn field(value: std.json.Value, key: []const u8) std.json.Value {
        return if (value == .object) value.object.get(key) orelse .null else .null;
    }

    fn string(value: std.json.Value) ?[]const u8 {
        return if (value == .string) value.string else null;
    }

    fn id(entry: std.json.Value) ?[]const u8 {
        return string(field(field(entry, "identifier"), "id"));
    }

    pub fn selected(self: *const Profile, identifier: []const u8, version: []const u8, relative_location: []const u8) bool {
        if (!self.exists) return true;
        for (self.entries.items) |entry| {
            const identifier_value = id(entry) orelse continue;
            if (!util.areSameExtensions(identifier, identifier_value)) continue;
            const selected_version = string(field(entry, "version")) orelse continue;
            if (!std.mem.eql(u8, version, selected_version)) continue;
            if (string(field(entry, "relativeLocation"))) |relative| {
                if (std.mem.eql(u8, relative, relative_location)) return true;
            } else if (string(field(field(entry, "location"), "path"))) |path| {
                if (std.mem.eql(u8, std.fs.path.basename(path), relative_location)) return true;
            }
        }
        return false;
    }

    pub fn metadata(self: *const Profile, identifier: []const u8, version: []const u8) ?std.json.Value {
        for (self.entries.items) |entry| {
            if (!util.areSameExtensions(id(entry) orelse continue, identifier)) continue;
            if (!std.mem.eql(u8, string(field(entry, "version")) orelse continue, version)) continue;
            return field(entry, "metadata");
        }
        return null;
    }

    pub fn remove(self: *Profile, identifier: []const u8) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (util.areSameExtensions(id(self.entries.items[index]) orelse "", identifier)) {
                _ = self.entries.orderedRemove(index);
            } else index += 1;
        }
    }

    pub fn select(self: *Profile, identifier: []const u8, version: []const u8, location: []const u8, metadata_value: ?std.json.Value) !void {
        const allocator = self.arena.allocator();
        var entry: std.json.ObjectMap = .empty;
        for (self.entries.items) |previous| {
            if (!util.areSameExtensions(id(previous) orelse "", identifier)) continue;
            if (previous == .object) entry = try previous.object.clone(allocator);
            break;
        }
        var identifier_object = field(.{ .object = entry }, "identifier");
        if (identifier_object != .object) identifier_object = .{ .object = .empty };
        try identifier_object.object.put(allocator, "id", .{ .string = try allocator.dupe(u8, identifier) });
        try entry.put(allocator, "identifier", identifier_object);
        try entry.put(allocator, "version", .{ .string = try allocator.dupe(u8, version) });
        try entry.put(allocator, "relativeLocation", .{ .string = try allocator.dupe(u8, std.fs.path.basename(location)) });
        var uri: std.json.ObjectMap = .empty;
        const path = try allocator.dupe(u8, location);
        if (std.fs.path.sep == '\\') std.mem.replaceScalar(u8, path, '\\', '/');
        const uri_path = if (path.len > 0 and path[0] != '/') try std.fmt.allocPrint(allocator, "/{s}", .{path}) else path;
        try uri.put(allocator, "scheme", .{ .string = "file" });
        try uri.put(allocator, "path", .{ .string = uri_path });
        try entry.put(allocator, "location", .{ .object = uri });
        if (metadata_value) |value| {
            const raw = try std.json.Stringify.valueAlloc(allocator, value, .{});
            const incoming = try std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{});
            var merged_metadata = field(.{ .object = entry }, "metadata");
            if (merged_metadata != .object) merged_metadata = .{ .object = .empty };
            if (incoming == .object) {
                var iterator = incoming.object.iterator();
                while (iterator.next()) |item| try merged_metadata.object.put(allocator, item.key_ptr.*, item.value_ptr.*);
                try entry.put(allocator, "metadata", merged_metadata);
            } else try entry.put(allocator, "metadata", incoming);
        }
        self.remove(identifier);
        try self.entries.append(.{ .object = entry });
    }

    pub fn save(self: *Profile, io: std.Io) !void {
        try storage.writeStateFile(self.allocator, io, self.path, std.json.Value{ .array = self.entries });
        self.exists = true;
    }
};
