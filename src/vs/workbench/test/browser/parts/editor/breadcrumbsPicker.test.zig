// Port of the file-picker decisions used by
// `src/vs/workbench/browser/parts/editor/breadcrumbsPicker.ts`.

const std = @import("std");
const picker = @import("../../../../browser/parts/editor/breadcrumbsPicker.zig");
const FileElement = @import("../../../../browser/parts/editor/breadcrumbsModel.zig").FileElement;
const inputDirectory = picker.inputDirectory;
const list = picker.list;
const freeEntries = picker.freeEntries;

test "breadcrumbsPicker: input directory and sorted children" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "picker");
    var file = try tmp.dir.createFile(io, "picker/b.txt", .{});
    file.close(io);
    try tmp.dir.createDirPath(io, "picker/a-dir");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = try std.fs.path.join(allocator, &.{ path_buffer[0..root_len], "picker" });
    defer allocator.free(root);

    const file_path = try std.fs.path.join(allocator, &.{ root, "b.txt" });
    defer allocator.free(file_path);
    const file_element = FileElement{ .path = file_path, .kind = .FILE };
    try std.testing.expectEqualStrings(root, inputDirectory(&file_element));

    const entries = try list(allocator, io, root);
    defer freeEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expect(entries[0].is_dir);
    try std.testing.expectEqualStrings("a-dir", entries[0].name);
    try std.testing.expectEqualStrings("b.txt", entries[1].name);
}

test "breadcrumbsPicker: file tree expands folders inline" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const ui = @import("ui");
    const file_icon = @import("../../../../browser/fileIcon.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "picker");
    try tmp.dir.createDirPath(io, "picker/a-dir");
    var nested = try tmp.dir.createFile(io, "picker/a-dir/nested.txt", .{});
    nested.close(io);
    var file = try tmp.dir.createFile(io, "picker/b.txt", .{});
    file.close(io);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = try std.fs.path.join(allocator, &.{ path_buffer[0..root_len], "picker" });
    defer allocator.free(root);

    const State = struct {
        var opened: usize = 0;
        fn open(_: *anyopaque, _: []const u8) !void {
            opened += 1;
        }
        fn icon(_: *anyopaque, path: []const u8) file_icon.Icon {
            return file_icon.forPath(path);
        }
        fn render(_: *anyopaque) void {}
    };
    var context: u8 = 0;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const file_picker = try picker.FilePicker.init(allocator, .{
        .context = @ptrCast(&context),
        .io = io,
        .arena = arena.allocator(),
        .open_file = State.open,
        .file_icon = State.icon,
        .request_render = State.render,
    });
    defer file_picker.deinit();

    try file_picker.showDirectory(root, null);
    try std.testing.expectEqual(@as(usize, 2), file_picker.count());
    const folder = file_picker.tree.renderedItem(0).?;
    try std.testing.expect(folder.is_dir);
    file_picker.tree.setSelectionElement(folder);
    try std.testing.expect(file_picker.handleKey(&.{ .key = .right }));
    try std.testing.expectEqual(@as(usize, 3), file_picker.count());

    file_picker.anchor = .{ .start = 3, .end = 10, .cursor = 8 };
    var grid = try ui.CellGrid.init(allocator, 40, 12);
    defer grid.deinit();
    try file_picker.render(&grid);
    try std.testing.expect(ui.cell.snap(file_picker.rect.w) > 3);
    // The overlay is anchored to the breadcrumb item's left edge; the arrow
    // follows the cursor inside that item.
    try std.testing.expectEqual(@as(usize, 3), ui.cell.snap(file_picker.rect.x));
    try std.testing.expectEqual(@as(usize, 5), file_picker.arrow_offset);

    // Hovering the tree paints the ancestor guide under the parent's twistie.
    _ = file_picker.handleMouse(&.{ .kind = .move, .x = 6, .y = 3 });
    try file_picker.render(&grid);
    try std.testing.expectEqual(@as(u32, 0x2502), grid.cluster[grid.index(6, 3)]);

    try std.testing.expect(file_picker.handleKey(&.{ .key = .left }));
    try std.testing.expectEqual(@as(usize, 2), file_picker.count());
}
