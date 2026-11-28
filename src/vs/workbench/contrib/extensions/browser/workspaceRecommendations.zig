// Port of the workspace recommendation file contract from
// `src/vs/workbench/contrib/extensions/browser/workspaceRecommendations.ts`.
// Reads explicit recommendations from workspace-folder extensions.json and
// workspace configuration files. Other recommendation providers are separate.
const std = @import("std");
const Workspace = @import("../../../../platform/workspace/common/workspace.zig").Workspace;
const config = @import("../../../../platform/configuration/common/configurationModels.zig");

pub fn read(allocator: std.mem.Allocator, io: std.Io, workspace: *const Workspace) ![][]u8 {
    var ids: std.ArrayList([]u8) = .empty;
    var ignored: std.ArrayList([]u8) = .empty;
    defer {
        for (ignored.items) |id| allocator.free(id);
        ignored.deinit(allocator);
    }
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    for (workspace.folders.items) |folder| {
        const path = try std.fs.path.join(allocator, &.{ folder.resource, ".vscode", "extensions.json" });
        defer allocator.free(path);
        try addFile(allocator, io, path, false, &ids, &ignored);
    }
    if (workspace.configuration) |path| try addFile(allocator, io, path, true, &ids, &ignored);
    var index: usize = 0;
    while (index < ids.items.len) {
        for (ignored.items) |id| {
            if (std.ascii.eqlIgnoreCase(id, ids.items[index])) {
                allocator.free(ids.orderedRemove(index));
                break;
            }
        } else index += 1;
    }
    return ids.toOwnedSlice(allocator);
}

fn addFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, nested: bool, ids: *std.ArrayList([]u8), ignored: *std.ArrayList([]u8)) !void {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return;
    defer allocator.free(raw);
    const clean = try config.stripJsonc(allocator, raw);
    defer allocator.free(clean);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, clean, .{}) catch return;
    defer parsed.deinit();
    var value = parsed.value;
    if (nested) {
        if (value != .object) return;
        value = value.object.get("extensions") orelse return;
    }
    if (value != .object) return;
    if (value.object.get("recommendations")) |recommendations| try addIds(allocator, recommendations, ids);
    if (value.object.get("unwantedRecommendations")) |recommendations| try addIds(allocator, recommendations, ignored);
}

fn validIdentifier(id: []const u8) bool {
    var parts = std.mem.splitScalar(u8, id, '.');
    for (0..2) |_| {
        const part = parts.next() orelse return false;
        if (part.len == 0 or !std.ascii.isAlphanumeric(part[0])) return false;
        for (part[1..]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return parts.next() == null;
}

fn addIds(allocator: std.mem.Allocator, recommendations: std.json.Value, ids: *std.ArrayList([]u8)) !void {
    if (recommendations != .array) return;
    for (recommendations.array.items) |item| {
        if (item != .string) continue;
        const id = item.string;
        if (!validIdentifier(id)) continue;
        for (ids.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, id)) break;
        } else {
            const copy = try std.ascii.allocLowerString(allocator, id);
            errdefer allocator.free(copy);
            try ids.append(allocator, copy);
        }
    }
}
