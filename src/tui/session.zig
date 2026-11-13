//! Terminal session storage for the workbench editor group.
//!
//! Upstream restores editor groups from `IStorageService` mementos produced by
//! `EditorGroupModel.serialize()`. The TUI has no storage service yet, so this
//! module writes the same serialized group shape as JSON to an explicit file.
//! The caller chooses the path; there is no hidden global session location.
//!
//! Only the editor-group state is stored. Dirty working copies need the
//! working-copy backup service, which is not ported, so unsaved buffers are
//! not restored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const group_mod = @import("../vs/workbench/common/editor/editorGroupModel.zig");
const editor_groups = @import("../vs/workbench/services/editor/common/editorGroupsService.zig");

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

pub fn save(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    data: *const SerializedEditorGroupModel,
) !void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const dto = SessionDto{
        .id = data.id,
        .locked = data.locked,
        .editors = @ptrCast(data.editors),
        .mru = data.mru,
        .preview = data.preview,
        .sticky = data.sticky,
    };
    try std.json.Stringify.value(dto, .{}, &out.writer);

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
    try atomic.file.writeStreamingAll(io, out.written());
    if (exists) {
        try atomic.replace(io);
    } else {
        try atomic.link(io);
    }
}

/// Loads a session file, or null when it does not exist. The returned value
/// owns its strings; free it with `deinit`.
pub fn load(allocator: Allocator, io: Io, path: []const u8) !?SerializedEditorGroupModel {
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSliceLeaky(SessionDto, allocator, bytes, .{});
    defer if (parsed.editors.len > 0) {
        allocator.free(@constCast(parsed.editors));
    };
    defer if (parsed.mru.len > 0) {
        allocator.free(@constCast(parsed.mru));
    };

    const editors = try allocator.alloc(SerializedEditorInput, parsed.editors.len);
    errdefer allocator.free(editors);
    var initialized: usize = 0;
    errdefer for (editors[0..initialized]) |entry| {
        allocator.free(entry.id);
        allocator.free(entry.value);
    };
    for (parsed.editors, 0..) |editor, index| {
        editors[index] = .{
            .id = try allocator.dupe(u8, editor.id),
            .value = try allocator.dupe(u8, editor.value),
        };
        initialized += 1;
    }

    return .{
        .id = parsed.id,
        .locked = parsed.locked,
        .editors = editors,
        .mru = try allocator.dupe(usize, parsed.mru),
        .preview = parsed.preview,
        .sticky = parsed.sticky,
    };
}

test "session: save and load an editor group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/session.json", .{tmp.sub_path});
    defer allocator.free(path);

    const editors = [_]SerializedEditorInput{
        .{ .id = @constCast("type.a"), .value = @constCast("/tmp/a.txt") },
        .{ .id = @constCast("type.b"), .value = @constCast("/tmp/b.txt") },
    };
    const mru = [_]usize{ 1, 0 };
    var data = SerializedEditorGroupModel{
        .id = 7,
        .locked = true,
        .editors = @constCast(&editors),
        .mru = @constCast(&mru),
        .preview = 1,
        .sticky = 0,
    };

    try save(allocator, io, path, &data);

    var loaded = (try load(allocator, io, path)).?;
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 7), loaded.id);
    try std.testing.expect(loaded.locked);
    try std.testing.expectEqual(@as(usize, 2), loaded.editors.len);
    try std.testing.expectEqualStrings("type.a", loaded.editors[0].id);
    try std.testing.expectEqualStrings("/tmp/a.txt", loaded.editors[0].value);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, loaded.mru);
    try std.testing.expectEqual(@as(?usize, 1), loaded.preview);
    try std.testing.expectEqual(@as(?isize, 0), loaded.sticky);
}

test "session: missing file loads as null" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.testing.expectEqual(
        @as(?SerializedEditorGroupModel, null),
        try load(allocator, io, ".zig-cache/tmp/does-not-exist-session.json"),
    );
}

const PartDto = struct {
    groups: []const SessionDto = &.{},
    active_group: usize = 0,
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
        .active_group = data.active_group,
    };
    try std.json.Stringify.value(dto, .{}, &out.writer);
    try writeAtomic(allocator, io, path, out.written());
}

pub fn loadPart(allocator: Allocator, io: Io, path: []const u8) !?editor_groups.SerializedEditorPart {
    const bytes = try readAll(allocator, io, path) orelse return null;
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSliceLeaky(PartDto, allocator, bytes, .{});
    defer if (parsed.groups.len > 0) allocator.free(@constCast(parsed.groups));
    defer for (parsed.groups) |group| {
        if (group.editors.len > 0) allocator.free(@constCast(group.editors));
        if (group.mru.len > 0) allocator.free(@constCast(group.mru));
    };

    if (parsed.groups.len == 0) return null;

    const groups = try allocator.alloc(group_mod.SerializedEditorGroupModel, parsed.groups.len);
    var initialized: usize = 0;
    errdefer {
        for (groups[0..initialized]) |*group| group.deinit(allocator);
        allocator.free(groups);
    }

    for (parsed.groups, 0..) |group, index| {
        groups[index] = try copyGroup(allocator, group);
        initialized += 1;
    }

    return .{
        .groups = groups,
        .active_group = @min(parsed.active_group, groups.len - 1),
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
        editors[index] = .{
            .id = try allocator.dupe(u8, editor.id),
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
    };

    try savePart(allocator, io, path, &data);

    var loaded = (try loadPart(allocator, io, path)).?;
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), loaded.groups.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.active_group);
    try std.testing.expectEqual(@as(u32, 2), loaded.groups[1].id);
    try std.testing.expect(loaded.groups[1].locked);
    try std.testing.expectEqualStrings("/tmp/b.txt", loaded.groups[1].editors[0].value);
}
