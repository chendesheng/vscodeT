//! Terminal session storage for the workbench editor group.
//!
//! Upstream restores editor groups from `IStorageService` mementos produced by
//! `EditorGroupModel.serialize()`. Terminal adaptation: the part now travels
//! through `InMemoryStorageService` + `Memento` (key `memento/editorPart`) when
//! saving; the explicit `--session` file is the host for the memento value.
//! Loading reads that value directly (no per-read service/DB setup). The caller
//! chooses the path; there is no hidden global session location. Older bare
//! `SerializedEditorPart` files still load.
//!
//! Only the editor-group state is stored. Dirty working copies need the
//! working-copy backup service, which is not ported, so unsaved buffers are
//! not restored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const group_mod = @import("../../../common/editor/editorGroupModel.zig");
const editor_groups = @import("../../../services/editor/common/editorGroupsService.zig");
const storage_mod = @import("../../../../platform/storage/common/storage.zig");
const InMemoryStorageService = storage_mod.InMemoryStorageService;
const memento_mod = @import("../../../common/memento.zig");
const Memento = memento_mod.Memento;
const MementoStore = memento_mod.MementoStore;

const session_memento_id = "editorPart";
const session_storage_key = "memento/" ++ session_memento_id;

const SerializedEditorGroupModel = group_mod.SerializedEditorGroupModel;
const SerializedEditorInput = group_mod.SerializedEditorInput;

const EditorDto = struct {
    id: []const u8,
    value: []const u8,
};

const SessionDto = struct {
    id: u32,
    locked: bool = false,
    editors: []const EditorDto = &.{},
    mru: []const usize = &.{},
    preview: ?usize = null,
    sticky: ?isize = null,
};

test "session: loadPart returns null for a missing file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.testing.expectEqual(
        @as(?editor_groups.SerializedEditorPart, null),
        try loadPart(allocator, io, ".zig-cache/tmp/does-not-exist-session-part.json"),
    );
}

const PartDto = struct {
    groups: []const SessionDto = &.{},
    activeGroup: ?u32 = null,
    mostRecentActiveGroups: []const u32 = &.{},
    // Input compatibility with sessions storing a group index.
    active_group: ?usize = null,
};

pub fn savePart(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    data: *const editor_groups.SerializedEditorPart,
) !void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const dto = PartDto{
        .groups = @ptrCast(data.groups),
        .activeGroup = if (data.active_group < data.groups.len) data.groups[data.active_group].id else null,
        .mostRecentActiveGroups = data.most_recent_active_groups,
    };
    try std.json.Stringify.value(dto, .{ .emit_null_optional_fields = false }, &out.writer);

    // Route the part through the storage service + memento, the same path the
    // workbench uses; the file is the terminal host for the memento value.
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();
    var store = MementoStore.init(allocator);
    defer store.deinit();
    var memento = try Memento.init(allocator, session_memento_id, &storage, &store);
    defer memento.deinit();

    const scoped = try memento.getMemento(.workspace, .machine);
    try scoped.put("part", .{ .string = out.written() });
    try memento.saveMemento();

    const stored = storage.get(session_storage_key, .workspace, null) orelse return error.MissingMemento;
    try writeAtomic(allocator, io, path, stored);
}

pub fn loadPart(allocator: Allocator, io: Io, path: []const u8) !?editor_groups.SerializedEditorPart {
    const bytes = try readAll(allocator, io, path) orelse return null;
    defer allocator.free(bytes);

    // Current format: the memento value (`{ "part": "<part json>" }`) written by
    // `savePart`; legacy files are bare `SerializedEditorPart` objects.
    const parsed = std.json.parseFromSlice(MementoPartDto, allocator, bytes, .{}) catch null;
    if (parsed) |memento_value| {
        defer memento_value.deinit();
        return try parsePart(allocator, memento_value.value.part);
    }
    return try parsePart(allocator, bytes);
}

const MementoPartDto = struct {
    part: []const u8,
};

fn parsePart(allocator: Allocator, bytes: []const u8) !?editor_groups.SerializedEditorPart {
    const parsed = try std.json.parseFromSlice(PartDto, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value.groups.len == 0) return null;

    const groups = try allocator.alloc(group_mod.SerializedEditorGroupModel, parsed.value.groups.len);
    var initialized: usize = 0;
    errdefer {
        for (groups[0..initialized]) |*group| group.deinit(allocator);
        allocator.free(groups);
    }

    for (parsed.value.groups, 0..) |group, index| {
        groups[index] = try copyGroup(allocator, group);
        initialized += 1;
    }

    const active_group = if (parsed.value.activeGroup) |active_id| index: {
        for (groups, 0..) |group, i| {
            if (group.id == active_id) break :index i;
        }
        break :index 0;
    } else @min(parsed.value.active_group orelse 0, groups.len - 1);
    return .{
        .groups = groups,
        .active_group = active_group,
        .most_recent_active_groups = try allocator.dupe(u32, parsed.value.mostRecentActiveGroups),
    };
}

fn copyGroup(allocator: Allocator, group: SessionDto) !group_mod.SerializedEditorGroupModel {
    const editors = try allocator.alloc(group_mod.SerializedEditorInput, group.editors.len);
    var initialized: usize = 0;
    errdefer {
        for (editors[0..initialized]) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.value);
        }
        allocator.free(editors);
    }
    for (group.editors, 0..) |editor, index| {
        const id = try allocator.dupe(u8, editor.id);
        errdefer allocator.free(id);
        editors[index] = .{
            .id = id,
            .value = try allocator.dupe(u8, editor.value),
        };
        initialized += 1;
    }

    return .{
        .id = group.id,
        .locked = group.locked,
        .editors = editors,
        .mru = try allocator.dupe(usize, group.mru),
        .preview = group.preview,
        .sticky = group.sticky,
    };
}

fn writeAtomic(allocator: Allocator, io: Io, path: []const u8, bytes: []const u8) !void {
    _ = allocator;
    const cwd = Io.Dir.cwd();
    var exists = true;
    const maybe_file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            exists = false;
            break :blk null;
        },
        else => return err,
    };
    if (maybe_file) |file| file.close(io);

    var atomic = try cwd.createFileAtomic(io, path, .{ .replace = exists });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    if (exists) {
        try atomic.replace(io);
    } else {
        try atomic.link(io);
    }
}

fn readAll(allocator: Allocator, io: Io, path: []const u8) !?[]u8 {
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

test "session: save and load multiple groups" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/part.json", .{tmp.sub_path});
    defer allocator.free(path);

    const editor_a = [_]group_mod.SerializedEditorInput{
        .{ .id = @constCast("type.a"), .value = @constCast("/tmp/a.txt") },
    };
    const editor_b = [_]group_mod.SerializedEditorInput{
        .{ .id = @constCast("type.b"), .value = @constCast("/tmp/b.txt") },
    };
    const group_a = group_mod.SerializedEditorGroupModel{
        .id = 1,
        .editors = @constCast(&editor_a),
        .mru = @constCast(&[_]usize{0}),
    };
    const group_b = group_mod.SerializedEditorGroupModel{
        .id = 2,
        .locked = true,
        .editors = @constCast(&editor_b),
        .mru = @constCast(&[_]usize{0}),
    };
    const groups = [_]group_mod.SerializedEditorGroupModel{ group_a, group_b };
    var data = editor_groups.SerializedEditorPart{
        .groups = @constCast(&groups),
        .active_group = 1,
        .most_recent_active_groups = &.{ 2, 1 },
    };

    try savePart(allocator, io, path, &data);

    var loaded = (try loadPart(allocator, io, path)).?;
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), loaded.groups.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.active_group);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, loaded.most_recent_active_groups);
    try std.testing.expectEqual(@as(u32, 2), loaded.groups[1].id);
    try std.testing.expect(loaded.groups[1].locked);
    try std.testing.expectEqualStrings("/tmp/b.txt", loaded.groups[1].editors[0].value);
}

test "session: savePart and loadPart round-trip through the memento" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/session-part.json", .{tmp.sub_path});
    defer allocator.free(path);

    const editors = [_]SerializedEditorInput{
        .{ .id = @constCast("type.a"), .value = @constCast("/tmp/a.txt") },
    };
    const mru = [_]usize{0};
    var data = editor_groups.SerializedEditorPart{
        .groups = @constCast(&[_]group_mod.SerializedEditorGroupModel{.{
            .id = 3,
            .locked = false,
            .editors = @constCast(&editors),
            .mru = @constCast(&mru),
            .preview = null,
            .sticky = null,
        }}),
        .active_group = 0,
    };

    try savePart(allocator, io, path, &data);

    const bytes = (try readAll(allocator, io, path)).?;
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"part\"") != null);

    var loaded = (try loadPart(allocator, io, path)).?;
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.groups.len);
    try std.testing.expectEqual(@as(u32, 3), loaded.groups[0].id);
    try std.testing.expectEqualStrings("type.a", loaded.groups[0].editors[0].id);
}

test "session: legacy bare part files still load" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/legacy-part.json", .{tmp.sub_path});
    defer allocator.free(path);

    const legacy = "{\"groups\":[{\"id\":2,\"editors\":[{\"id\":\"type.x\",\"value\":\"/tmp/x\"}],\"mru\":[0]}],\"active_group\":0}";
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(legacy);
    try writeAtomic(allocator, io, path, out.written());

    var loaded = (try loadPart(allocator, io, path)).?;
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), loaded.groups[0].id);
    try std.testing.expectEqualStrings("type.x", loaded.groups[0].editors[0].id);
}
