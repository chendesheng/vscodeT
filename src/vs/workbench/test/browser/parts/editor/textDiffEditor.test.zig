// Terminal snapshot input and diff pane integration cases for
// `src/vs/workbench/browser/parts/editor/textDiffEditor.ts`.
// The test root injects the real terminal editor view.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const diff = @import("../../../../browser/parts/editor/textDiffEditor.zig");
const SnapshotEditorInput = diff.SnapshotEditorInput;

pub fn Tests(comptime View: type) type {
    return struct {
        const DiffView = diff.DiffView(View);
        test "SnapshotEditorInput: identity, read-only and no dirty state" {
            const allocator = testing.allocator;
            const original = try SnapshotEditorInput.init(allocator, "/repo/a.zig", "HEAD", "/repo/a.zig::HEAD::original");
            defer original.destroy();
            const modified = try SnapshotEditorInput.init(allocator, "/repo/a.zig", "Working Tree", "/repo/a.zig::working::modified");
            defer modified.destroy();

            try testing.expectEqualStrings("a.zig", original.base.getName());
            try testing.expectEqualStrings("HEAD", original.base.getDescription(.SHORT).?);
            try testing.expect(original.base.isReadonly());
            try testing.expect(!original.base.isDirty());
            try testing.expect(original.base.matches(.{ .input = &original.base }));
            try testing.expect(!original.base.matches(.{ .input = &modified.base }));
            try testing.expect((try original.base.save(0)) != null);
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

            view.widget.sash_layout.ratio = 0.7;
            try view.replace("a\nb\nc", "a\nB", 80, 10, .{});
            try testing.expectEqual(@as(usize, 1), view.widget.changeCount());
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
