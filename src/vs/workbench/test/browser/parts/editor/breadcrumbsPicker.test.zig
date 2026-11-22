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

test "breadcrumbsPicker: popup lists items, navigates and accepts" {
    const allocator = std.testing.allocator;
    const ui = @import("ui");
    const Popup = picker.Popup;
    const PopupItem = picker.PopupItem;

    const State = struct {
        var accepted: ?[]const u8 = null;
        var closed: usize = 0;
        fn accept(_: *anyopaque, item: *const PopupItem) !void {
            accepted = item.id;
        }
        fn close(_: *anyopaque) void {
            closed += 1;
        }
    };
    State.accepted = null;
    State.closed = 0;
    var context: u8 = 0;
    const popup = try Popup.init(allocator);
    defer popup.deinit();
    popup.on_accept_context = @ptrCast(&context);
    popup.on_accept = State.accept;
    popup.on_close_context = @ptrCast(&context);
    popup.on_close = State.close;

    const items = [_]PopupItem{
        .{ .id = "f:/tmp/a.zig", .label = "a.zig", .kind = .file },
        .{ .id = "d:/tmp/src", .label = "src", .kind = .folder, .description = "folder" },
    };
    try popup.open(&items, 3, 1, "d:/tmp/src");
    try std.testing.expect(popup.isVisible());
    try std.testing.expectEqual(@as(usize, 1), popup.selectedIndex().?);
    try std.testing.expectEqualStrings("d:/tmp/src", popup.selectedItem().?.id);

    var grid = try ui.CellGrid.init(allocator, 40, 12);
    defer grid.deinit();
    try popup.render(&grid);
    try std.testing.expect(ui.cell.snap(popup.rect.w) > 3);

    var up = ui.KeyEvent{ .key = .up };
    try std.testing.expect(popup.handleKey(&up));
    try std.testing.expectEqual(@as(usize, 0), popup.selectedIndex().?);
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(popup.handleKey(&enter));
    try std.testing.expectEqualStrings("f:/tmp/a.zig", State.accepted.?);

    // A click outside closes the context-view popup.
    var outside = ui.MouseEvent{ .kind = .down, .x = 0, .y = 11, .button = .left };
    try std.testing.expect(popup.handleMouse(&outside));
    try std.testing.expect(!popup.isVisible());
    try std.testing.expectEqual(@as(usize, 1), State.closed);
}
