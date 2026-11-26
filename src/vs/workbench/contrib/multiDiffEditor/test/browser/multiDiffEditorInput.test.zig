// Port of the input ownership and dirty-state contracts in
// `src/vs/workbench/contrib/multiDiffEditor/test/browser/multiDiffEditorInput.test.ts`.
const std = @import("std");
const testing = std.testing;
const input_mod = @import("../../browser/multiDiffEditorInput.zig");
const Editor = @import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const FileEditorInput = @import("../../../files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const TextResourceEditorInput = @import("../../../../../workbench/common/editor/textResourceEditorInput.zig").TextResourceEditorInput;
const dispatch = @import("../../../../../base/common/windowDispatch.zig");

test "MultiDiffEditorInput: aggregate dirty events and save/revert retain both real file input references" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "working.txt", .data = "old" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "working.txt", testing.allocator);
    defer testing.allocator.free(path);
    const working = try Editor.createFromText(testing.allocator, testing.io, "old", path, 80, 10);
    var file = try FileEditorInput.init(testing.allocator, working);
    defer file.deinit();
    const original = try TextResourceEditorInput.init(testing.allocator, testing.io, path, "Original", "base", .{ .scheme = "git", .path = .{ .raw = path }, .query = .{ .raw = "HEAD" } });
    defer original.destroy();
    const input = try input_mod.MultiDiffEditorInput.create(testing.allocator, "scm-history-item:/repo?commit", "Commit", false);
    defer input.destroy();
    try testing.expectEqualStrings("Commit", input.base.getName());
    try input.setResolvedItems(&.{.{
        .original = .{ .uri = original.document.model.uri(), .input = .{ .resource = original } },
        .modified = .{ .uri = working.model.uri(), .input = .{ .file = file } },
    }});
    try testing.expectEqualStrings("Commit (1 file)", input.base.getName());
    try testing.expect(input.base.isReadonly());
    try testing.expect(!input.base.isDirty());
    var queue: dispatch.Queue = .{ .io = testing.io };
    const vm = try input.getViewModel(testing.io, &queue, null);
    try testing.expectEqual(working.document, vm.items[0].modified);
    try testing.expectEqual(original.document, vm.items[0].original);
    try working.setCursorPosition(.{ .lineNumber = 1, .column = 4 });
    try working.insertText("!");
    try testing.expect(input.base.isDirty());
    _ = try input.base.save(1);
    try testing.expect(!input.base.isDirty());
    const saved = try tmp.dir.readFileAlloc(testing.io, "working.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("old!", saved);
    try working.insertText("?");
    try testing.expect(input.base.isDirty());
    try input.base.revert(1);
    try testing.expect(!input.base.isDirty());
    try testing.expectEqualStrings("old!", try working.model.borrowLineContent(1));
    try testing.expect(input.base.close_handler != null and !input.base.close_handler.?.show_confirm(input.base.close_handler.?.context));
}

test "MultiDiffEditorInput: input identity is the source URI and resource-only entries remain binary" {
    const a = try input_mod.MultiDiffEditorInput.create(testing.allocator, "scm-history-item:/repo?ref=first", null, false);
    defer a.destroy();
    const b = try input_mod.MultiDiffEditorInput.create(testing.allocator, "scm-history-item:/repo?ref=first", "Different label", true);
    defer b.destroy();
    const c = try input_mod.MultiDiffEditorInput.create(testing.allocator, "scm-history-item:/repo?ref=second", null, false);
    defer c.destroy();
    try testing.expect(a.base.matches(.{ .input = &b.base }));
    try testing.expect(!a.base.matches(.{ .input = &c.base }));
    try a.setResolvedItems(&.{.{
        .modified = .{ .uri = .{ .scheme = "file", .path = .{ .raw = "/binary.png" } } },
    }});
    try testing.expectEqualStrings("Multi Diff Editor (1 file)", a.base.getName());
    var queue: dispatch.Queue = .{ .io = testing.io };
    const vm = try a.getViewModel(testing.io, &queue, null);
    try testing.expect(vm.items[0].isBinary());
    try testing.expect(vm.items[0].documentDiffItem.original == null);
}
