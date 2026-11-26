// Terminal snapshot input and diff pane integration cases for
// `src/vs/workbench/browser/parts/editor/textDiffEditor.ts`.
// The test root injects the real terminal editor view.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const diff = @import("../../../../browser/parts/editor/textDiffEditor.zig");
const TextResourceEditorInput = diff.TextResourceEditorInput;

pub fn Tests(comptime View: type) type {
    return struct {
        const DiffView = diff.DiffView(View);
        test "TextResourceEditorInput: identity, read-only and no dirty state" {
            const allocator = testing.allocator;
            const original = try TextResourceEditorInput.init(allocator, testing.io, "/repo/a.zig", "HEAD", "a", .{ .scheme = "git", .path = .{ .raw = "/repo/a.zig" }, .query = .{ .raw = "HEAD" } });
            defer original.destroy();
            const modified = try TextResourceEditorInput.init(allocator, testing.io, "/repo/a.zig", "Working Tree", "b", .{ .scheme = "git", .path = .{ .raw = "/repo/a.zig" }, .query = .{ .raw = "working" } });
            defer modified.destroy();

            try testing.expectEqualStrings("a.zig", original.base.getName());
            try testing.expectEqualStrings("HEAD", original.base.getDescription(.SHORT).?);
            try testing.expect(original.base.isReadonly());
            try testing.expect(!original.base.isDirty());
            try testing.expect(original.base.matches(.{ .input = &original.base }));
            try testing.expect(!original.base.matches(.{ .input = &modified.base }));
            try testing.expect((try original.base.save(0)) != null);
        }

        test "DiffView: shares a file input and forwards its dirty state without replacing it on refresh" {
            const Editor = @import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
            const FileInput = @import("../../../../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
            const allocator = testing.allocator;
            const source = try Editor.createFromText(allocator, testing.io, "modified\nend", "/repo/a.zig", 80, 8);
            const file = try FileInput.init(allocator, source);
            defer file.deinit();
            const view = try DiffView.createWithSources(View.init, allocator, testing.io, .{ .original_path = "/repo/a.zig", .modified_path = "/repo/a.zig", .original_label = "HEAD", .modified_label = "Working Tree" }, "original\nend", "modified\nend", 80, 8, .{}, .{ .modified = .{ .file = file } }, null);
            defer view.destroy();
            try testing.expectEqual(source.model, view.widget.modifiedModel());
            try testing.expect(!view.widget.modified_editor.isReadOnly());
            try testing.expect(!view.input().isReadonly());
            try testing.expectEqual(file.interface(), view.diff_input.modified);
            try view.widget.revert(view.widget.state().?.mappings[0].line_range_mapping);
            try testing.expect(view.input().isDirty());
            try testing.expectEqualStrings("original", try source.model.borrowLineContent(1));
            try view.replace("first\nend", "stale disk content\nend", 80, 8, .{});
            try testing.expectEqual(source.model, view.widget.modifiedModel());
            try testing.expectEqualStrings("original", try source.model.borrowLineContent(1));
            try testing.expect(view.input().isDirty());
            view.swapSides();
            try testing.expect(view.widget.modified_editor.isReadOnly());
            try testing.expect(!view.widget.original_editor.isReadOnly());
            try testing.expect(view.input().isReadonly());
            try testing.expect(!view.input().isDirty());
        }

        test "DiffView: opens a diff tab input with distinct snapshot keys" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            const view = try DiffView.create(
                View.init,
                allocator,
                io,
                .{
                    .original_path = "/repo/a.zig",
                    .modified_path = "/repo/a.zig",
                    .original_label = "HEAD",
                    .modified_label = "Working Tree",
                },
                "a\nb",
                "a\nB",
                80,
                10,
                .{},
            );
            defer view.destroy();

            try testing.expect(std.mem.indexOf(u8, view.input().getName(), "HEAD") != null);
            try testing.expect(std.mem.indexOf(u8, view.input().getName(), "Working Tree") != null);
            try testing.expect(view.widget.changeCount() == 1);
            try testing.expect(view.widget.modified_editor.isReadOnly());
            try testing.expect(view.widget.original_editor.isReadOnly());

            const mounted_widget = view.widget;
            const old_original = view.widget.originalModel();
            const old_modified = view.widget.modifiedModel();
            try testing.expectEqual(old_original, view.original_input.resolve().model);
            try testing.expectEqual(old_modified, view.modified_input.resolve().model);
            try testing.expect(!std.mem.eql(u8, view.original_input.interface().resource.?, view.modified_input.interface().resource.?));
            view.widget.sash_layout.ratio = 0.7;
            try view.replace("a\nb\nc", "a\nB", 80, 10, .{});
            try testing.expectEqual(@as(usize, 1), view.widget.changeCount());
            try testing.expectEqual(mounted_widget, view.widget);
            try testing.expectEqual(old_original, view.widget.originalModel());
            try testing.expectEqual(old_modified, view.widget.modifiedModel());
            try testing.expectEqual(@as(f64, 0.7), view.widget.sash_layout.getRatio(0.5, true));
            view.swapSides();
            try testing.expectEqualStrings("Working Tree", view.model.original_label);
            try testing.expectEqualStrings("HEAD", view.model.modified_label);
            try testing.expectEqualStrings("a.zig (Working Tree ↔ HEAD)", view.input().getName());
            try testing.expectEqual(view.original_input.interface(), view.diff_input.original);
            try testing.expectEqual(view.modified_input.interface(), view.diff_input.modified);
            const existing_widget = view.widget;
            const original_model = view.widget.originalModel();
            const modified_model = view.widget.modifiedModel();
            var options = view.widget.options;
            options.render_side_by_side = false;
            try testing.expect(try view.updateOptions(options));
            try testing.expect(view.widget.inline_mode);
            try testing.expectEqual(existing_widget, view.widget);
            try testing.expectEqual(original_model, view.widget.originalModel());
            try testing.expectEqual(modified_model, view.widget.modifiedModel());
            try testing.expect(!(try view.updateOptions(options)));
        }
    };
}
