// Port of `src/vs/workbench/contrib/multiDiffEditor/test/browser/multiDiffEditorWithFileList.test.ts`.
// Browser row queries are expressed through the same compressed tree model
// and actual terminal cell render; native mouse down pairs replace dblclick.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const common = @import("../../common/multiDiffEditor.zig");
const composite_mod = @import("../../browser/multiDiffEditorWithFileListWidget.zig");
const pane_mod = @import("../../browser/multiDiffEditor.zig");
const input_mod = @import("../../browser/multiDiffEditorInput.zig");
const model = @import("../../../../../editor/browser/widget/multiDiffEditor/model.zig");
const vm_mod = @import("../../../../../editor/browser/widget/multiDiffEditor/multiDiffEditorViewModel.zig");
const dispatch = @import("../../../../../base/common/windowDispatch.zig");
const storage = @import("../../../../../platform/storage/common/storage.zig");
const config = @import("../../../../../platform/configuration/common/configuration.zig");
const Emitter = @import("../../../../../base/common/event.zig").Emitter;
const Workspace = @import("../../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;

fn file(path: []const u8) std.Uri {
    return .{ .scheme = "file", .path = .{ .raw = path } };
}
fn binaryItem(original: ?std.Uri, modified: ?std.Uri) !*model.IDocumentDiffItem {
    return model.IDocumentDiffItem.create(testing.allocator, if (original) |uri| .{ .uri = uri } else null, if (modified) |uri| .{ .uri = uri } else null, .{});
}
const MockConfig = struct {
    enabled: std.json.Value,
    changed: Emitter(config.Change),
    fn get(context: *anyopaque, key: []const u8) ?*const std.json.Value {
        const self: *MockConfig = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, key, common.multiDiffEditorExperimentalFileListSetting)) return &self.enabled;
        return null;
    }
    fn interface(self: *MockConfig) config.IConfigurationService {
        return .{ .context = self, .get_value = get, .on_did_change_configuration = &self.changed };
    }
};

pub fn Tests(comptime View: type) type {
    return struct {
        const Composite = composite_mod.MultiDiffEditorWithFileListWidget(View);
        const Pane = pane_mod.MultiDiffEditor(View);
        const FileList = Composite.FileList;
        const Fixture = struct {
            documents: model.MultiDiffEditorModel = undefined,
            store: storage.InMemoryStorageService = undefined,
            queue: dispatch.Queue = .{ .io = testing.io },
            composite: *Composite = undefined,
            vm: *vm_mod.MultiDiffEditorViewModel = undefined,
            workspace: ?*Workspace = null,
            fn init(self: *@This(), items: []const *model.IDocumentDiffItem, enabled: bool, mode: common.MultiDiffEditorFileListViewMode, width: usize, height: usize, root: ?[]const u8, stored_width: ?usize) !void {
                self.documents = .init(testing.allocator);
                errdefer self.documents.deinit();
                self.store = .init(testing.allocator);
                errdefer self.store.deinit();
                if (stored_width) |value| try self.store.store(common.FILE_LIST_WIDTH_STORAGE_KEY, .{ .number = @floatFromInt(value) }, .profile, .user);
                if (root) |path| self.workspace = try Workspace.initWithFolders(testing.allocator, "workspace", &.{path});
                errdefer if (self.workspace) |workspace| workspace.deinit();
                try self.documents.setDocuments(.{ .items = items });
                self.composite = try Composite.create(testing.allocator, testing.io, &self.queue, .{ .context = self, .view_factory = View.init }, .noCardsNonCompact, self.store.interface(), self.workspace, null, enabled, mode, .right);
                errdefer self.composite.destroy();
                self.vm = try self.composite.widget.createViewModel(self.documents.interface(), null);
                errdefer self.vm.destroy();
                errdefer self.composite.setViewModel(null, true) catch {};
                try self.composite.layoutWidget(width, height);
                try self.composite.setViewModel(self.vm, true);
            }
            fn deinit(self: *@This()) void {
                self.composite.destroy();
                self.vm.destroy();
                self.documents.deinit();
                if (self.workspace) |workspace| workspace.deinit();
                self.store.deinit();
            }
            fn list(self: *@This()) *FileList {
                return self.composite.file_list.?;
            }
            fn draw(self: *@This(), frame: *ui.Frame) !void {
                frame.begin();
                try self.composite.paint(frame, 0, 0, self.composite.width, self.composite.height);
            }
            fn click(self: *@This(), row: usize) !void {
                var mouse: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = self.composite.listX() + 4, .y = row };
                try testing.expect(try self.composite.dispatchMouse(&mouse));
            }
        };
        fn fileNames(list: *FileList, expected: []const []const u8) !void {
            try testing.expectEqual(expected.len, list.files.len);
            for (list.files, expected) |row, name| try testing.expectEqualStrings(name, row.name);
        }
        fn diffNames(vm: *vm_mod.MultiDiffEditorViewModel, expected: []const []const u8) !void {
            try testing.expectEqual(expected.len, vm.items.len);
            for (vm.items, expected) |item, name| {
                const uri = @import("../../browser/multiDiffEditorFileList.zig").getItemUri(item);
                try testing.expectEqualStrings(name, std.fs.path.basename(uri.path.raw));
            }
        }
        fn rowName(list: *FileList, index: usize, expected: []const u8) !void {
            const node = list.tree.renderedNode(index) orelse return error.MissingTreeRow;
            const elements = node.element.?.elements;
            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(testing.allocator);
            for (elements, 0..) |element, i| {
                if (i != 0) try result.append(testing.allocator, '/');
                try result.appendSlice(testing.allocator, switch (element.*) {
                    .file => |value| value.name,
                    .folder => |value| value.name,
                });
            }
            try testing.expectEqualStrings(expected, result.items);
        }
        fn testExperimental(enabled: bool) !void {
            var store = storage.InMemoryStorageService.init(testing.allocator);
            defer store.deinit();
            var cfg: MockConfig = .{ .enabled = .{ .bool = enabled }, .changed = .init(testing.allocator) };
            defer cfg.changed.deinit();
            var queue: dispatch.Queue = .{ .io = testing.io };
            const input = try input_mod.MultiDiffEditorInput.create(testing.allocator, "multi-diff-editor:test", null, false);
            defer input.destroy();
            try input.setResolvedItems(&.{});
            const pane = try Pane.create(testing.allocator, testing.io, input, &queue, .{ .context = &queue, .view_factory = View.init }, null, 80, 15, true, .{ .configuration_service = cfg.interface(), .storage_service = store.interface() });
            defer pane.destroy();
            try testing.expectEqual(enabled, pane.composite != null);
            try testing.expectEqual(enabled, pane.fileListAvailable());
            try testing.expectEqual(enabled, pane.fileListVisible());
        }
        test "View: MultiDiffEditorWithFileList uses original widget when experimental setting is false" {
            try testExperimental(false);
        }
        test "View: MultiDiffEditorWithFileList uses composite widget when experimental setting is true" {
            try testExperimental(true);
        }

        test "View: MultiDiffEditorWithFileList focus action shows a hidden list before focusing" {
            var store = storage.InMemoryStorageService.init(testing.allocator);
            defer store.deinit();
            var cfg: MockConfig = .{ .enabled = .{ .bool = true }, .changed = .init(testing.allocator) };
            defer cfg.changed.deinit();
            var queue: dispatch.Queue = .{ .io = testing.io };
            const input = try input_mod.MultiDiffEditorInput.create(testing.allocator, "multi-diff-editor:test", null, false);
            defer input.destroy();
            try input.setResolvedItems(&.{.{ .modified = .{ .uri = file("/repo/a.png") } }});
            const pane = try Pane.create(testing.allocator, testing.io, input, &queue, .{ .context = &queue, .view_factory = View.init }, null, 80, 15, true, .{ .configuration_service = cfg.interface(), .storage_service = store.interface() });
            defer pane.destroy();
            try common.toggleMultiDiffEditorFileList(store.interface());
            try testing.expect(!pane.fileListVisible() and pane.fileListAvailable() and !pane.fileListFocused());
            try pane.focusFileList();
            try testing.expect(pane.fileListVisible() and pane.fileListAvailable() and pane.fileListFocused());
        }

        test "View: MultiDiffEditorWithFileList orders the input diffs like the changed files list" {
            var store = storage.InMemoryStorageService.init(testing.allocator);
            defer store.deinit();
            var config_on: MockConfig = .{ .enabled = .{ .bool = true }, .changed = .init(testing.allocator) };
            defer config_on.changed.deinit();
            var config_off: MockConfig = .{ .enabled = .{ .bool = false }, .changed = .init(testing.allocator) };
            defer config_off.changed.deinit();
            var queue: dispatch.Queue = .{ .io = testing.io };
            const values = [_]input_mod.ResolvedItem{
                .{ .modified = .{ .uri = file("/repo/src/c.png") } },
                .{ .modified = .{ .uri = file("/repo/d.png") } },
                .{ .modified = .{ .uri = file("/repo/docs/b.png") } },
                .{ .modified = .{ .uri = file("/repo/src/a.png") } },
            };
            const input_on = try input_mod.MultiDiffEditorInput.create(testing.allocator, "multi-diff-editor:on", null, false);
            defer input_on.destroy();
            const input_off = try input_mod.MultiDiffEditorInput.create(testing.allocator, "multi-diff-editor:off", null, false);
            defer input_off.destroy();
            try input_on.setResolvedItems(&values);
            try input_off.setResolvedItems(&values);
            const pane = try Pane.create(testing.allocator, testing.io, input_on, &queue, .{ .context = &queue, .view_factory = View.init }, null, 80, 30, true, .{ .configuration_service = config_on.interface(), .storage_service = store.interface() });
            defer pane.destroy();
            const plain = try Pane.create(testing.allocator, testing.io, input_off, &queue, .{ .context = &queue, .view_factory = View.init }, null, 80, 30, true, .{ .configuration_service = config_off.interface(), .storage_service = store.interface() });
            defer plain.destroy();
            try fileNames(pane.composite.?.file_list.?, &.{ "d.png", "b.png", "a.png", "c.png" });
            try diffNames(pane.widget.getViewModel().?, &.{ "d.png", "b.png", "a.png", "c.png" });
            try common.setMultiDiffEditorFileListViewMode(store.interface(), .tree);
            try fileNames(pane.composite.?.file_list.?, &.{ "b.png", "a.png", "c.png", "d.png" });
            try diffNames(pane.widget.getViewModel().?, &.{ "b.png", "a.png", "c.png", "d.png" });
            try common.setMultiDiffEditorFileListViewMode(store.interface(), .list);
            try fileNames(pane.composite.?.file_list.?, &.{ "d.png", "b.png", "a.png", "c.png" });
            try diffNames(plain.widget.getViewModel().?, &.{ "c.png", "d.png", "b.png", "a.png" });
            try input_on.setResourceOrder(null);
            try diffNames(pane.widget.getViewModel().?, &.{ "c.png", "d.png", "b.png", "a.png" });
        }

        test "View: MultiDiffEditorWithFileList follows the visible item and opens single/double clicked files" {
            const added = try binaryItem(null, file("/repo/added.png"));
            defer added.release();
            const deleted = try binaryItem(file("/repo/deleted.png"), null);
            defer deleted.release();
            const renamed = try binaryItem(file("/repo/old.png"), file("/repo/renamed.png"));
            defer renamed.release();
            const modified = try binaryItem(.{ .scheme = "original", .path = .{ .raw = "/repo/modified.png" } }, file("/repo/modified.png"));
            defer modified.release();
            const literal = try binaryItem(null, file("/repo/$(zap).png"));
            defer literal.release();
            var f: Fixture = .{};
            try f.init(&.{ added, deleted, renamed, modified, literal }, true, .list, 80, 20, null, null);
            defer f.deinit();
            try fileNames(f.list(), &.{ "$(zap).png", "added.png", "deleted.png", "modified.png", "renamed.png" });
            const statuses = [_]u21{ 'A', 'A', 'D', 'M', 'R' };
            for (statuses, f.list().files) |status, row| try testing.expectEqual(status, row.status.letter());
            try testing.expectEqual(f.vm.items[0], f.list().currentSelection().?);
            var frame = try ui.Frame.init(testing.allocator, 80, 20);
            defer frame.deinit();
            try f.draw(&frame);
            try f.click(4);
            try testing.expectEqual(f.vm.items[2], f.vm.activeDiffItem.?);
            try testing.expect(f.composite.isFileListFocused());
            try f.vm.items[1].setCollapsed(true);
            try f.draw(&frame);
            try f.click(2);
            try f.click(2);
            try testing.expectEqual(f.vm.items[1], f.list().currentSelection().?);
            try testing.expect(!f.vm.items[1].collapsed and !f.composite.isFileListFocused());
        }

        test "View: MultiDiffEditorWithFileList accessibility name includes help shortcut only with verbosity" {
            const a = testing.allocator;
            const with_hint = try FileList.widgetAriaLabel(a, true, true, "Alt+F1");
            defer a.free(with_hint);
            const disabled = try FileList.widgetAriaLabel(a, true, false, "Alt+F1");
            defer a.free(disabled);
            const no_binding = try FileList.widgetAriaLabel(a, true, true, null);
            defer a.free(no_binding);
            try testing.expectEqualStrings("Changed Files, use Alt+F1 for accessibility help", with_hint);
            try testing.expectEqualStrings("Changed Files", disabled);
            try testing.expectEqualStrings("Changed Files, run the Open Accessibility Help command for more information", no_binding);
        }

        test "View: MultiDiffEditorWithFileList builds compressed folders and switches back to a flat tree" {
            const a = try binaryItem(file("/repo/src/app/a.png"), file("/repo/src/app/a.png"));
            defer a.release();
            const b = try binaryItem(file("/repo/src/app/b.png"), file("/repo/src/app/b.png"));
            defer b.release();
            const c = try binaryItem(.{ .scheme = "git", .path = .{ .raw = "/repo/docs/c.png" } }, null);
            defer c.release();
            const d = try binaryItem(null, file("/repo/lib/util/deep/d.png"));
            defer d.release();
            var f: Fixture = .{};
            try f.init(&.{ a, b, c, d }, true, .tree, 80, 30, null, null);
            defer f.deinit();
            const names = [_][]const u8{ "docs", "c.png", "lib/util/deep", "d.png", "src/app", "a.png", "b.png" };
            try testing.expectEqual(names.len, f.list().tree.count());
            for (names, 0..) |name, index| try rowName(f.list(), index, name);
            try f.list().open(f.vm.items[2], true);
            try testing.expectEqual(f.vm.items[2], f.list().currentSelection().?);
            try f.composite.setPreferences(true, .list, .right);
            try fileNames(f.list(), &.{ "c.png", "d.png", "a.png", "b.png" });
            try testing.expectEqual(f.vm.items[2], f.list().currentSelection().?);
        }

        test "View: MultiDiffEditorWithFileList sorts files by path in list and folders before files in tree" {
            const a = try binaryItem(null, file("/repo/src/c.png"));
            defer a.release();
            const b = try binaryItem(null, file("/repo/d.png"));
            defer b.release();
            const c = try binaryItem(null, file("/repo/docs/b.png"));
            defer c.release();
            const d = try binaryItem(null, file("/repo/src/a.png"));
            defer d.release();
            var f: Fixture = .{};
            try f.init(&.{ a, b, c, d }, true, .tree, 80, 30, null, null);
            defer f.deinit();
            try fileNames(f.list(), &.{ "b.png", "a.png", "c.png", "d.png" });
            try f.composite.setPreferences(true, .list, .right);
            try fileNames(f.list(), &.{ "d.png", "b.png", "a.png", "c.png" });
        }

        test "View: MultiDiffEditorWithFileList starts compressed tree at the workspace folder" {
            const a = try binaryItem(.{ .scheme = "git", .path = .{ .raw = "/repo/src/app/a.png" } }, .{ .scheme = "git", .path = .{ .raw = "/repo/src/app/a.png" } });
            defer a.release();
            const b = try binaryItem(.{ .scheme = "git", .path = .{ .raw = "/repo/src/app/b.png" } }, null);
            defer b.release();
            var f: Fixture = .{};
            try f.init(&.{ a, b }, true, .tree, 80, 20, "/repo", null);
            defer f.deinit();
            try testing.expectEqual(@as(usize, 3), f.list().tree.count());
            try rowName(f.list(), 0, "src/app");
            try rowName(f.list(), 1, "a.png");
            try rowName(f.list(), 2, "b.png");
        }

        test "View: MultiDiffEditorWithFileList preserves a file and folder sharing the same path" {
            const a = try binaryItem(file("/repo/config"), null);
            defer a.release();
            const b = try binaryItem(null, file("/repo/config/settings.json"));
            defer b.release();
            var f: Fixture = .{};
            try f.init(&.{ a, b }, true, .tree, 80, 20, null, null);
            defer f.deinit();
            try testing.expectEqual(@as(usize, 3), f.list().tree.count());
            try rowName(f.list(), 0, "config");
            try rowName(f.list(), 1, "config");
            try rowName(f.list(), 2, "settings.json");
            try f.list().open(f.vm.items[0], true);
            try testing.expectEqual(f.vm.items[0], f.list().currentSelection().?);
            try f.list().open(f.vm.items[1], true);
            try testing.expectEqual(f.vm.items[1], f.list().currentSelection().?);
        }

        test "View: MultiDiffEditorWithFileList shows the list only when enabled and wide enough using stored width" {
            var f: Fixture = .{};
            try f.init(&.{}, true, .list, 80, 20, null, 340);
            defer f.deinit();
            try testing.expect(f.composite.isFileListVisible);
            try testing.expectEqual(@as(usize, 20), f.composite.current_list_width);
            try f.composite.layoutWidget(Composite.MIN_DIFF_EDITOR_WIDTH + Composite.MIN_FILE_LIST_WIDTH, 20);
            try testing.expect(!f.composite.isFileListVisible and f.composite.file_list != null);
            try f.composite.layoutWidget(80, 20);
            try testing.expectEqual(@as(usize, 20), f.composite.current_list_width);
            try f.composite.setPreferences(false, .list, .right);
            try testing.expect(!f.composite.isFileListVisible and f.composite.file_list == null);
            try f.composite.setPreferences(true, .list, .right);
            try testing.expect(f.composite.isFileListVisible);
            try testing.expectEqual(@as(usize, 20), f.composite.current_list_width);
        }

        test "View: MultiDiffEditorWithFileList fits diffs into groups narrower than minimum while hidden" {
            var f: Fixture = .{};
            try f.init(&.{}, true, .list, 8, 10, null, null);
            defer f.deinit();
            try testing.expectEqual(@as(usize, 8), f.composite.diffWidth());
            try testing.expect(!f.composite.isFileListVisible);
            try f.composite.setPreferences(false, .list, .right);
            try testing.expectEqual(@as(usize, 8), f.composite.diffWidth());
        }

        test "View: MultiDiffEditorWithFileList moves retained list and preserves focus and preferred width" {
            var f: Fixture = .{};
            try f.init(&.{}, true, .list, 80, 20, null, 340);
            defer f.deinit();
            const list = f.list();
            try f.composite.focusFileList();
            try f.composite.setPreferences(true, .list, .left);
            try testing.expectEqual(list, f.list());
            try testing.expectEqual(@as(usize, 0), f.composite.listX());
            try testing.expect(f.composite.isFileListFocused());
            try f.composite.setPreferences(true, .list, .right);
            try testing.expectEqual(list, f.list());
            try testing.expect(f.composite.isFileListFocused());
            try f.composite.layoutWidget(30, 20);
            try testing.expect(!f.composite.isFileListVisible);
            try f.composite.layoutWidget(80, 20);
            try testing.expectEqual(@as(usize, 20), f.composite.current_list_width);
        }
    };
}
