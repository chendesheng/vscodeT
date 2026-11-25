// Terminal workbench integration tests, driven through the host and service APIs.
const shell = @import("../vs/workbench/browser/workbench.zig");
const Focus = shell.Focus;
const GroupPane = shell.GroupPane;
const TabKeyResult = shell.TabKeyResult;
const Workbench = shell.Workbench;
const launchTestTerminal = shell.launchTestTerminal;
const pumpSidebarForTests = shell.pumpSidebarForTests;
const seedFile = shell.seedFile;
const sendDragMouse = shell.sendDragMouse;
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ui = @import("ui");
const editor_css = @import("../vs/editor/browser/editorCss.zig");
const editor_group_watermark = @import("../vs/workbench/browser/parts/editor/editorGroupWatermark.zig");
const Tab = @import("../vs/workbench/browser/parts/editor/editorPane.zig").Tab;
const FileEditorInput = @import("../vs/workbench/contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const FileEditorSerializer = @import("../vs/workbench/contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorSerializer;
const editor_factory = @import("../vs/workbench/common/editor/editorFactory.zig");
const editor_options = @import("../vs/editor/common/config/editorOptions.zig");
const file_icon = @import("../vs/workbench/browser/fileIcon.zig");
const Sidebar = @import("../vs/workbench/contrib/files/browser/views/explorerView.zig").Sidebar;
const zen_mode_contribution = @import("../vs/workbench/browser/workbench.zenMode.contribution.zig");
const outline_mod = @import("../vs/workbench/services/outline/browser/outline.zig");
const OutlineEditor = outline_mod.OutlineEditor;
const markers_common = @import("../vs/workbench/contrib/markers/common/markers.zig");
const PROBLEMS_CONTAINER_ID = markers_common.Markers.MARKERS_CONTAINER_ID;
const TERMINAL_CONTAINER_ID = "terminal";
const panel_part_mod = @import("../vs/workbench/browser/parts/panel/panelPart.zig");
const search_widget_mod = @import("../vs/workbench/contrib/search/browser/searchWidget.zig");
const editor_groups = @import("../vs/workbench/services/editor/common/editorGroupsService.zig");
const extensions_registry = @import("../vs/workbench/services/extensions/common/extensionsRegistry.zig");
const time_compat = @import("../vs/base/common/timeCompat.zig");
const editor_input = @import("../vs/workbench/common/editor/editorInput.zig");
const EditorInput = editor_input.EditorInput;
const Range = @import("../vs/editor/common/core/range.zig").Range;
const languages = @import("../vs/editor/common/languages.zig");
const CancellationToken = @import("../vs/base/common/cancellation.zig").CancellationToken;
const ImagePreviewEditorInput = @import("../vs/workbench/contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInput;
const ImagePreviewEditorInputSerializer = @import("../vs/workbench/contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInputSerializer;
const std_uri = @import("../vs/base/common/stdUri.zig");
const markers_mod = @import("../vs/platform/markers/common/markers.zig");
const Position = @import("../vs/editor/common/core/position.zig").Position;
const EOL = @import("../vs/editor/common/core/misc/eolCounter.zig").EOL;
const encoding_mod = @import("../vs/workbench/services/textfile/common/encoding.zig");
const terminal_service_mod = @import("../vs/workbench/contrib/terminal/browser/terminalService.zig");
const terminal_view = @import("../vs/workbench/contrib/terminal/browser/terminalRenderer.zig");
const TerminalService = terminal_service_mod.TerminalService;

fn clickStatusEntry(workbench: *Workbench, id: []const u8) !bool {
    const part = workbench.statusbar.main_part;
    const handle = part.model.findHandle(id) orelse return false;
    const y = ui.cell.snap(workbench.statusBarRect().y);
    const width = ui.cell.snap(workbench.statusBarRect().w);
    var x: usize = 0;
    while (x < width) : (x += 1) {
        const hit = part.hitAt(x, y) catch null;
        if (hit) |value| {
            switch (value) {
                .entry => |candidate| if (candidate == handle) {
                    var event = ui.MouseEvent{
                        .kind = .down,
                        .x = x,
                        .y = y,
                        .button = .left,
                    };
                    return workbench.handleStatusbarMouse(&event);
                },
                .part => {},
            }
        }
    }
    return false;
}

fn closeQuickAccess(workbench: *Workbench) !void {
    var escape = ui.KeyEvent{ .key = .escape };
    _ = try workbench.handleQuickAccessKey(&escape);
    try std.testing.expect(!workbench.isQuickAccessOpen());
}

fn frameText(allocator: Allocator, frame: *const ui.Frame) ![]u8 {
    var text = std.array_list.Managed(u8).init(allocator);
    errdefer text.deinit();
    var row: usize = 0;
    while (row < frame.prev.rows) : (row += 1) {
        const line = try frame.prev.rowText(allocator, row);
        defer allocator.free(line);
        try text.appendSlice(line);
        try text.append('\n');
    }
    return text.toOwnedSlice();
}

fn grid_attr_italic(grid: *const ui.CellGrid, col: usize, row: usize) bool {
    if (row >= grid.rows or col >= grid.cols) return false;
    return grid.attrs[row * grid.cols + col] & ui.cell.Attr.italic != 0;
}

fn paneTextAlloc(allocator: Allocator, pane: *@import("imagePreview.zig").ImagePreviewPane) ![]u8 {
    const surface = &(pane.surface orelse return allocator.alloc(u8, 0));
    var text = std.array_list.Managed(u8).init(allocator);
    errdefer text.deinit();
    var row: usize = 0;
    while (row < surface.grid().rows) : (row += 1) {
        const line = try surface.grid().rowText(allocator, row);
        defer allocator.free(line);
        try text.appendSlice(line);
        try text.append('\n');
    }
    return text.toOwnedSlice();
}

fn pumpOpenForTests(workbench: *Workbench) void {
    var guard: usize = 0;
    while (workbench.pending_open != null and guard < 1000) : (guard += 1) {
        _ = workbench.pollAsyncReads();
        if (workbench.pending_open != null) std.Io.sleep(workbench.async_io, .fromMilliseconds(1), .awake) catch {};
    }
}

fn seedBinary(
    allocator: Allocator,
    io: Io,
    tmp: *std.testing.TmpDir,
    name: []const u8,
    contents: []const u8,
) ![]u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = contents });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPathFile(io, name, &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

fn tagScale(scale: @import("../vs/workbench/contrib/mediaPreview/browser/imageViewer.zig").Scale) f64 {
    return switch (scale) {
        .fit => 1,
        .number => |value| value,
    };
}

const test_png_1x1 = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
    0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
    0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,
};

fn writeKeybindingsFile(
    tmp: *std.testing.TmpDir,
    io: Io,
    path: []const u8,
    allocator: Allocator,
    contents: []const u8,
) !void {
    _ = path;
    _ = allocator;
    var file = try tmp.dir.createFile(io, "keybindings.json", .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

test "Workbench: empty editor renders the watermark and runs its shortcuts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "watermark.txt", "");
    defer allocator.free(path);
    const workbench = try Workbench.init(allocator, io, &.{}, 90, 32);
    defer workbench.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try workbench.render(&out.writer);
    const initial = try frameText(allocator, &workbench.frame);
    defer allocator.free(initial);
    try std.testing.expect(std.mem.indexOf(u8, initial, "▟████▙▄  ▗▄████████▀▘▐██████") != null);
    const commands = std.mem.indexOf(u8, initial, "Show All Commands").?;
    const terminal = std.mem.indexOf(u8, initial, "Toggle Terminal").?;
    const search = std.mem.indexOf(u8, initial, "Find in Files").?;
    try std.testing.expect(commands < terminal and terminal < search);
    try std.testing.expect(std.mem.indexOf(u8, initial, "Ctrl+Shift+P") != null);

    const watermark = &workbench.activePane().?.watermark.?;
    const commands_row = watermark.shortcuts.?.first_child.?;
    const terminal_row = commands_row.next.?;
    const search_row = terminal_row.next.?;
    const label_x = commands_row.first_child.?.next.?.asElement().rect.x;
    try std.testing.expectEqual(label_x, terminal_row.first_child.?.next.?.asElement().rect.x);
    try std.testing.expectEqual(label_x, search_row.first_child.?.next.?.asElement().rect.x);
    try std.testing.expect(workbench.handleWatermarkKey(&.{ .key = .tab }));
    try std.testing.expectEqual(commands_row, watermark.root.document.focusedElement().?);
    try std.testing.expect(workbench.handleWatermarkKey(&.{ .key = .down }));
    try std.testing.expectEqual(terminal_row, watermark.root.document.focusedElement().?);
    try std.testing.expect(workbench.handleWatermarkKey(&.{ .key = .up }));
    try std.testing.expectEqual(commands_row, watermark.root.document.focusedElement().?);
    try std.testing.expect(workbench.handleWatermarkKey(&.{ .key = .enter }));
    try std.testing.expect(workbench.quick_access.isOpen());
    var escape = ui.KeyEvent{ .key = .escape };
    _ = try workbench.handleQuickAccessKey(&escape);

    const hit = search_row.first_child.?.prev.?.asElement().rect;
    var mouse = ui.MouseEvent{ .kind = .move, .x = ui.cell.snap(hit.x), .y = ui.cell.snap(hit.y) };
    try std.testing.expect(workbench.handleTabMouse(&mouse));
    try std.testing.expectEqual(ui.Pointer.pointer, workbench.pointer);
    mouse.kind = .down;
    mouse.button = .left;
    try std.testing.expect(workbench.handleTabMouse(&mouse));
    try std.testing.expectEqualStrings("search", workbench.activity_bar_part.active_id.?);

    try workbench.openPath(path);
    try workbench.render(&out.writer);
    try std.testing.expectEqual(ui.style.Display.none, watermark.root.declaredDisplay());
    try std.testing.expect(workbench.activeTab() != null);
    _ = try workbench.closeActive();
    try workbench.render(&out.writer);
    try std.testing.expectEqual(ui.style.Display.block, watermark.root.declaredDisplay());
}

test "Workbench: watermark tips respond to resized panes, settings, and keybindings" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "watermark-keybindings.json",
        \\[
        \\  { "key": "ctrl+alt+g", "command": "workbench.action.showCommands" },
        \\  { "key": "alt+shift+t", "command": "-workbench.action.terminal.toggleTerminal" }
        \\]
    );
    defer allocator.free(path);
    const settings_path = try seedFile(allocator, io, &tmp, "watermark-settings.json", "{}");
    defer allocator.free(settings_path);
    const workbench = try Workbench.init(allocator, io, &.{}, 90, 32);
    defer workbench.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    try workbench.setKeybindingsPaths(&.{path});
    try workbench.resize(90, 12);
    try workbench.render(&out.writer);
    const short = try frameText(allocator, &workbench.frame);
    defer allocator.free(short);
    try std.testing.expect(std.mem.indexOf(u8, short, "Ctrl+Alt+G") != null);
    try std.testing.expect(std.mem.indexOf(u8, short, "Find in Files") != null);
    try std.testing.expect(std.mem.indexOf(u8, short, "Toggle Terminal") == null);
    try std.testing.expect(std.mem.indexOf(u8, short, "▗▄██▙▄▖") == null);

    workbench.ensureConfigurationReady();
    try workbench.setUserConfigurationValue(editor_group_watermark.settings_key, .{ .bool = false });
    try workbench.resize(90, 32);
    try workbench.render(&out.writer);
    const inactive = try frameText(allocator, &workbench.frame);
    defer allocator.free(inactive);
    try std.testing.expect(std.mem.indexOf(u8, inactive, "▗▄██▙▄▖") != null);
    try std.testing.expect(std.mem.indexOf(u8, inactive, "Show All Commands") == null);
    try std.testing.expect(!workbench.handleWatermarkKey(&.{ .key = .tab }));
}

test "Workbench: threaded tokenizer shuts down after tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "tokenized.zig", "const value = 1; // comment\n");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 10);
    defer workbench.deinit();
    workbench.enableAsyncTokenization();
    try std.testing.expect(workbench.textmate_background != null);
}

test "Workbench: sticky scroll paints scope headers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source = std.array_list.Managed(u8).init(allocator);
    defer source.deinit();
    try source.appendSlice("async function stickyScope() {\n");
    var line_buffer: [64]u8 = undefined;
    for (0..30) |index| {
        const line = try std.fmt.bufPrint(&line_buffer, "\tconst value{d} = {d};\n", .{ index, index });
        try source.appendSlice(line);
    }
    try source.appendSlice("}\n");

    const path = try seedFile(allocator, io, &tmp, "sticky.js", source.items);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 12);
    defer workbench.deinit();
    const tab = workbench.activeTab().?;
    try tab.ensureControllers();
    if (tab.controllers) |controllers| {
        _ = controllers.sticky.onTick(std.math.maxInt(i64));
    }
    _ = tab.editor.setTopViewLine(5);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const text = try frameText(allocator, &workbench.frame);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "async function stickyScope") != null);
}

test "Workbench: declarative markdown configuration applies to open tabs" {
    const allocator = std.testing.allocator;
    var registry = extensions_registry.scan(allocator, &.{"vscode/extensions/markdown-basics"}) catch return error.SkipZigTest;
    defer registry.deinit();
    if (registry.language("markdown") == null) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(time_compat.io, .{ .sub_path = "README.md", .data = "# Hello\n" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPathFile(time_compat.io, "README.md", &buffer);

    const workbench = try Workbench.init(allocator, time_compat.io, &.{buffer[0..length]}, 40, 9);
    defer workbench.deinit();
    workbench.setDeclarativeExtensions(&registry);

    workbench.ensureConfigurationReady();
    const key = "diffEditor.ignoreTrimWhitespace";
    const markdown = @import("../vs/platform/configuration/common/configuration.zig").Overrides{ .override_identifier = "markdown" };
    try std.testing.expectEqual(false, workbench.configuration.?.getValue(key, markdown).?.bool);
    try workbench.setUserSettingsPaths(&.{});
    try std.testing.expectEqual(false, workbench.configuration.?.getValue(key, markdown).?.bool);

    const tab = workbench.activeTab().?;
    try std.testing.expectEqualStrings("markdown", tab.editor.languageId());
    const config = tab.editor.language_service.getLanguageConfiguration("markdown") orelse return error.TestUnexpectedResult;
    try std.testing.expect(config.comments != null);
    try std.testing.expectEqualStrings("<!--", config.comments.?.blockComment.?[0]);
    try std.testing.expect(config.folding.?.offSide orelse false);
}

test "Workbench: opens two files, switches tabs and closes them" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 40, 9);
    defer workbench.deinit();

    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqualStrings("b.txt", workbench.activeTab().?.input.getName());

    try workbench.activeTab().?.ensureControllers();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "b.txt") != null);
    try std.testing.expectEqual(@as(usize, 2), workbench.cursorCell().?.row);

    try workbench.activateIndex(0);
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.getName());
    try workbench.switchTab(1);
    try std.testing.expectEqualStrings("b.txt", workbench.activeTab().?.input.getName());

    const ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.getName());
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());
}

test "Workbench: ownsEditor follows tab ownership across close" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "owned-a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "owned-b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 40, 9);
    defer workbench.deinit();

    const closed = workbench.activeTab().?.editor;
    const kept = workbench.part.group_views.items[0].tabs.items[0].editor;
    try std.testing.expect(workbench.ownsEditor(closed));
    try std.testing.expect(workbench.ownsEditor(kept));

    try workbench.activeTab().?.ensureControllers();
    const ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    // `closed` is only compared, never dereferenced: the tab close freed it.
    try std.testing.expect(!workbench.ownsEditor(closed));
    try std.testing.expect(workbench.ownsEditor(kept));
}

test "Workbench: reopening an open file reuses its tab and editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "reuse.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();

    const tab = workbench.activeTab().?;
    const editor = tab.editor;
    try workbench.openPath(path);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(workbench.activeTab().? == tab);
    try std.testing.expect(workbench.activeTab().?.editor == editor);
}

test "Workbench: opening a new file rebuilds its view once" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "one.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "two.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{path_a}, 40, 9);
    defer workbench.deinit();

    try workbench.openPath(path_b);
    const tab = workbench.activeTab().?;
    try std.testing.expectEqual(@as(usize, 0), tab.view.renderCount());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expectEqual(@as(usize, 1), tab.view.renderCount());
}

test "Workbench: markdown preview toggle changes the current editor in place" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "preview.md", "# Title\n\nHello **world**\n");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 14);
    defer workbench.deinit();

    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    try std.testing.expect(tab.isMarkdown());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const hit = pane.title_action_hit orelse return error.TestUnexpectedResult;
    const row = ui.cell.snap(pane.rect.y);
    const grid = &workbench.frame.prev;
    try std.testing.expectEqual(@as(u32, 0x25EB), grid.cluster[grid.index(hit.start, row)]);
    try std.testing.expectEqual(@as(u32, 0x2315), grid.cluster[grid.index(hit.start + 1, row)]);

    try workbench.toggleMarkdownPreview(pane);
    try std.testing.expect(tab.markdown_preview != null);
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());

    var close_key = ui.KeyEvent{ .key = .{ .char = 'v' }, .mods = .{ .ctrl = true, .shift = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&close_key));
    try std.testing.expect(tab.markdown_preview == null);
    try std.testing.expect(try workbench.handleGlobalKey(&close_key));
    try std.testing.expect(tab.markdown_preview != null);
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "world") != null);

    const preview_surface = &tab.markdown_preview.?.surface.?;
    var saw_title = false;
    var saw_world = false;
    var preview_row: usize = 0;
    while (preview_row < preview_surface.grid().rows) : (preview_row += 1) {
        const text = try preview_surface.grid().rowText(allocator, preview_row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "Title") != null) saw_title = true;
        if (std.mem.indexOf(u8, text, "world") != null) saw_world = true;
    }
    try std.testing.expect(saw_title);
    try std.testing.expect(saw_world);
}

test "Workbench: markdown preview title action is absent for plain text" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "plain.txt", "plain\n");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 50, 10);
    defer workbench.deinit();
    const pane = workbench.activePane().?;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(pane.title_action_hit == null);
    try workbench.toggleMarkdownPreview(pane);
    try std.testing.expect(pane.activeTab().?.markdown_preview == null);
}

test "Workbench: markdown preview follows editor scroll and can reveal the editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    var line: usize = 0;
    while (line < 80) : (line += 1) {
        try body.writer.print("paragraph {d}\n\n", .{line});
    }
    const path = try seedFile(allocator, io, &tmp, "scroll.md", body.written());
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 18);
    defer workbench.deinit();
    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    try workbench.showMarkdownPreviewToSide();
    const preview_tab = workbench.activeTab().?;
    try std.testing.expect(preview_tab.markdown_preview != null);

    _ = tab.editor.setTopViewLine(30);
    const now = @import("../vs/base/common/timeCompat.zig").milliTimestamp();
    _ = workbench.markdownPreviewTick(now + 60);
    try std.testing.expect(preview_tab.markdown_preview.?.scroll > 0);
    _ = workbench.markdownPreviewTick(now + 120);

    const before = tab.editor.topViewLine();
    var wheel = ui.MouseEvent{
        .kind = .wheel,
        .x = 2,
        .y = 1,
        .delta_y = 20,
    };
    _ = preview_tab.markdown_preview.?.handleMouse(&wheel, now + 100);
    try std.testing.expect(tab.editor.topViewLine() != before);
}

test "Workbench: split duplicates the active editor and shares its buffer" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "split_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "split_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);

    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 3), workbench.tabCount());
    try std.testing.expectEqualStrings("split_b.txt", workbench.activeTab().?.input.getName());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    // Both panes paint the shared buffer; tab labels may be clipped.
    try std.testing.expect(std.mem.count(u8, out.written(), "beta") >= 2);

    // The source group keeps its tabs; the new group gets a copy of the active
    // editor, not an empty pane.
    const first_pane = workbench.part.group_views.items[0];
    const second_pane = workbench.part.group_views.items[1];
    try std.testing.expectEqual(@as(usize, 2), first_pane.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), second_pane.tabs.items.len);
    try std.testing.expect(first_pane.activeTab() != null);
    try std.testing.expect(second_pane.activeTab() != null);
    try std.testing.expectEqualStrings("split_b.txt", first_pane.activeTab().?.input.getName());
    try std.testing.expectEqualStrings("split_b.txt", second_pane.tabs.items[0].input.getName());
    try std.testing.expect(first_pane.tabs.items[1].editor.model == second_pane.tabs.items[0].editor.model);

    // Editing either pane updates the shared model and dirty state.
    try workbench.activeTab().?.editor.insertText("X");
    const first_text = try first_pane.tabs.items[1].editor.model.getLineContent(1);
    defer first_text.deinit();
    try std.testing.expectEqualStrings("Xbeta", first_text.items);
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());
    try std.testing.expect(first_pane.tabs.items[1].editor.isDirty());
    try workbench.activeTab().?.editor.undo();

    // Splitting again duplicates the active tab into a third group.
    try workbench.splitActive(.vertical);
    try std.testing.expectEqual(@as(usize, 3), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 4), workbench.tabCount());
}

test "Workbench: split copy shares rendered edits after changing focus" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "split_edit.txt", "alpha\nbeta");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 12);
    defer workbench.deinit();
    const left = workbench.activePane().?;
    _ = try workbench.commands.execute("workbench.action.splitEditorRight");
    const right = workbench.activePane().?;
    try std.testing.expect(right != left);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    // Let sticky scroll complete its initial update before changing focus.
    const inactive = right.activeTab().?;
    _ = inactive.controllers.?.sticky.onTick(std.math.maxInt(i64));
    _ = try workbench.commands.execute("workbench.action.focusLeftGroup");
    try std.testing.expectEqual(left, workbench.activePane().?);
    try workbench.render(&out.writer);

    const active = workbench.activeTab().?;
    try std.testing.expect(!inactive.view.needsRender());
    try active.editor.deleteRight();
    // The input loop refreshes the active view before painting the workbench.
    try active.view.refresh();
    try workbench.render(&out.writer);

    const grid = &workbench.frame.prev;
    for ([_]*GroupPane{ left, right }) |pane| {
        const x = ui.cell.snap(pane.rect.x) + pane.activeTab().?.editor.gutterWidth();
        const y = ui.cell.snap(pane.rect.y) + pane.chromeHeight();
        for ("lpha", 0..) |ch, col| {
            try std.testing.expectEqual(@as(u32, ch), grid.cluster[grid.index(x + col, y)]);
        }
        for ("beta", 0..) |ch, col| {
            try std.testing.expectEqual(@as(u32, ch), grid.cluster[grid.index(x + col, y + 1)]);
        }
    }
}

test "Workbench: editor group focus stays put when wheeling over another pane" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(
        allocator,
        io,
        &tmp,
        "wheel.txt",
        "first\nsecond\nthird\nfourth\nfifth\nsixth\nseventh\neighth\n" ++
            "ninth\ntenth\neleventh\ntwelfth\nthirteenth\nfourteenth\nfifteenth\n",
    );
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 12);
    defer workbench.deinit();
    const left = workbench.activePane().?;
    try workbench.splitActive(.horizontal);
    const right = workbench.activePane().?;
    const left_tab = left.activeTab().?;
    const right_tab = right.activeTab().?;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(right_tab.view.isFocused());
    const surface = &workbench.editor_surface.?;
    try std.testing.expectEqual(surface.document(), left_tab.view.root_node.?.document);
    try std.testing.expectEqual(surface.document(), right_tab.view.root_node.?.document);
    try std.testing.expectEqual(left.dom.?.editor_container, left_tab.element.?.parent.?);
    try std.testing.expectEqual(right.dom.?.editor_container, right_tab.element.?.parent.?);
    try std.testing.expect(left.dom.?.split_view.hasClass(editor_css.splitview.Class.split_view_view));
    try std.testing.expect(left_tab.view.root_node.?.hasClass(editor_css.code_editor.Class.monaco_editor));

    const x = ui.cell.snap(left.rect.x) + left_tab.editor.gutterWidth();
    const y = ui.cell.snap(left.rect.y) + left.chromeHeight();
    var wheel = ui.MouseEvent{ .kind = .wheel, .x = x, .y = y, .delta_y = 3 };
    try std.testing.expect(!workbench.handleTabMouse(&wheel));
    const target = workbench.editorMouseEvent(wheel) orelse return error.TestExpectedWheelTarget;
    try std.testing.expectEqual(left_tab, target.tab);
    const hit = (try surface.elementFromPoint(x, y)) orelse return error.TestExpectedWheelTarget;
    surface.document().dispatchMouse(hit, &wheel);
    try workbench.render(&out.writer);

    try std.testing.expectEqual(@as(usize, 4), left_tab.editor.topViewLine());
    try std.testing.expectEqual(@as(usize, 1), right_tab.editor.topViewLine());
    try std.testing.expectEqual(right_tab, workbench.activeTab().?);
    try std.testing.expect(right_tab.view.isFocused());
    try std.testing.expect(!left_tab.view.isFocused());
    const grid = &workbench.frame.prev;
    try std.testing.expectEqual(@as(u32, 'f'), grid.cluster[grid.index(x, y)]);
    try std.testing.expectEqual(@as(u32, 'o'), grid.cluster[grid.index(x + 1, y)]);
}

test "Workbench: editor group focus, new group and close group commands" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "group_focus.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();
    const first = workbench.activePane().?;

    _ = try workbench.commands.execute("workbench.action.newGroupRight");
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    const second = workbench.activePane().?;
    try std.testing.expect(second != first);
    try std.testing.expect(second.activeTab() == null);

    _ = try workbench.commands.execute("workbench.action.focusLeftGroup");
    try std.testing.expect(workbench.activePane().? == first);
    _ = try workbench.commands.execute("workbench.action.focusRightGroup");
    try std.testing.expect(workbench.activePane().? == second);
    _ = try workbench.commands.execute("workbench.action.focusFirstEditorGroup");
    try std.testing.expect(workbench.activePane().? == first);
    _ = try workbench.commands.execute("workbench.action.focusLastEditorGroup");
    try std.testing.expect(workbench.activePane().? == second);
    _ = try workbench.commands.execute("workbench.action.focusPreviousGroup");
    try std.testing.expect(workbench.activePane().? == first);
    _ = try workbench.commands.execute("workbench.action.focusNextGroup");
    try std.testing.expect(workbench.activePane().? == second);
    _ = try workbench.commands.execute("workbench.action.focusActiveEditorGroup");
    try std.testing.expect(workbench.activePane().? == second);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    _ = try workbench.commands.execute("workbench.action.closeGroup");
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expect(workbench.activePane().? == first);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());

    // Ctrl-W / closeActiveEditor on an empty group closes the group.
    _ = try workbench.commands.execute("workbench.action.newGroupRight");
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    _ = try workbench.closeActive();
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
}

test "Workbench: new group below and above focus commands" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "group_vertical.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 14);
    defer workbench.deinit();
    const first = workbench.activePane().?;
    _ = try workbench.commands.execute("workbench.action.newGroupBelow");
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    const below = workbench.activePane().?;
    try std.testing.expect(ui.cell.snap(below.rect.y) > ui.cell.snap(first.rect.y));
    _ = try workbench.commands.execute("workbench.action.focusAboveGroup");
    try std.testing.expect(workbench.activePane().? == first);
    _ = try workbench.commands.execute("workbench.action.focusBelowGroup");
    try std.testing.expect(workbench.activePane().? == below);
}

test "Workbench: move and duplicate editor group commands" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "group_move_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "group_move_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    const source = workbench.activePane().?;

    _ = try workbench.commands.execute("workbench.action.moveActiveEditorGroupLeft");
    const moved = try workbench.part.orderedViews(allocator);
    defer allocator.free(moved);
    try std.testing.expectEqual(@as(usize, 2), moved.len);
    try std.testing.expect(moved[0] == source);
    try std.testing.expect(workbench.activePane().? == source);

    _ = try workbench.commands.execute("workbench.action.duplicateActiveEditorGroupRight");
    try std.testing.expectEqual(@as(usize, 3), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 4), workbench.tabCount());
    const copy = workbench.activePane().?;
    try std.testing.expect(copy != source);
    try std.testing.expect(copy.activeTab() != null);
    try std.testing.expectEqualStrings("group_move_b.txt", copy.activeTab().?.input.getName());
    try std.testing.expect(copy.activeTab().?.editor.model == source.activeTab().?.editor.model);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
}

test "Workbench: move editor into group and split editor into group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "into_group_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "into_group_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    const first = workbench.part.group_views.items[0];
    const second = workbench.part.group_views.items[1];
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 3), workbench.tabCount());

    // Split the non-active tab from the source group into the right group.
    workbench.service.activateGroup(first.group);
    try workbench.activateIndex(0);
    try std.testing.expectEqualStrings("into_group_a.txt", workbench.activeTab().?.input.getName());
    _ = try workbench.commands.execute("workbench.action.splitEditorToRightGroup");
    try std.testing.expectEqual(@as(usize, 4), workbench.tabCount());
    try std.testing.expect(workbench.activePane().? == second);
    try std.testing.expectEqualStrings("into_group_a.txt", workbench.activeTab().?.input.getName());
    try std.testing.expect(second.tabs.items.len == 2);

    // Move the active editor back into the left group; the matching input
    // already open there wins, so no duplicate tab is created.
    _ = try workbench.commands.execute("workbench.action.moveEditorToLeftGroup");
    try std.testing.expectEqual(@as(usize, 3), workbench.tabCount());
    try std.testing.expect(workbench.activePane().? == first);
    try std.testing.expectEqual(@as(usize, 2), first.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), second.tabs.items.len);

    // Join the two remaining groups.
    _ = try workbench.commands.execute("workbench.action.joinTwoGroups");
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
}

test "Workbench: splitEditorToRightGroup creates a group without a neighbour" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "split_into_new_group.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();
    const source = workbench.activePane().?;
    _ = try workbench.commands.execute("workbench.action.splitEditorToRightGroup");
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    const target = workbench.activePane().?;
    try std.testing.expect(target != source);
    try std.testing.expect(target.activeTab().?.editor.model == source.activeTab().?.editor.model);
    try std.testing.expect(ui.cell.snap(target.rect.x) > ui.cell.snap(source.rect.x));
}

test "Workbench: directional split commands place the copy on each side" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "directional.txt", "alpha");
    defer allocator.free(path);

    const DirectionCase = struct {
        command: []const u8,
        expected: editor_groups.GroupDirection,
    };
    const cases = [_]DirectionCase{
        .{ .command = "workbench.action.splitEditorLeft", .expected = .LEFT },
        .{ .command = "workbench.action.splitEditorRight", .expected = .RIGHT },
        .{ .command = "workbench.action.splitEditorUp", .expected = .UP },
        .{ .command = "workbench.action.splitEditorDown", .expected = .DOWN },
    };
    for (cases) |case| {
        const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
        defer workbench.deinit();
        const source = workbench.part.group_views.items[0];
        _ = try workbench.commands.execute(case.command);
        try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
        try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
        const copy = workbench.part.group_views.items[1];
        switch (case.expected) {
            .LEFT => try std.testing.expect(ui.cell.snap(copy.rect.x) < ui.cell.snap(source.rect.x)),
            .RIGHT => try std.testing.expect(ui.cell.snap(copy.rect.x) > ui.cell.snap(source.rect.x)),
            .UP => try std.testing.expect(ui.cell.snap(copy.rect.y) < ui.cell.snap(source.rect.y)),
            .DOWN => try std.testing.expect(ui.cell.snap(copy.rect.y) > ui.cell.snap(source.rect.y)),
        }
        try std.testing.expect(copy.activeTab() != null);
        try std.testing.expect(copy.activeTab().?.editor.model == source.activeTab().?.editor.model);
    }
}

test "Workbench: splitEditor follows openSideBySideDirection" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "direction_setting.txt", "alpha");
    defer allocator.free(path);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{root});
    defer allocator.free(settings_path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    workbench.ensureConfigurationReady();
    try workbench.setUserConfigurationValue("workbench.editor.openSideBySideDirection", .{ .string = "down" });
    try std.testing.expectEqual(editor_groups.GroupDirection.DOWN, workbench.preferredSideBySideDirection());

    const source = workbench.part.group_views.items[0];
    _ = try workbench.commands.execute("workbench.action.splitEditor");
    const copy = workbench.part.group_views.items[1];
    try std.testing.expect(ui.cell.snap(copy.rect.y) > ui.cell.snap(source.rect.y));
}

test "Workbench: directional group navigation and join all groups" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "nav_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "nav_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqualStrings("nav_b.txt", workbench.activeTab().?.input.getName());

    try workbench.navigateGroup(.left);
    try std.testing.expectEqualStrings("nav_b.txt", workbench.activeTab().?.input.getName());
    // Switch the source group to its other tab, then navigate across groups.
    try workbench.activateIndex(0);
    try std.testing.expectEqualStrings("nav_a.txt", workbench.activeTab().?.input.getName());
    try workbench.navigateGroup(.right);
    try std.testing.expectEqualStrings("nav_b.txt", workbench.activeTab().?.input.getName());
    try workbench.navigateGroup(.left);
    try std.testing.expectEqualStrings("nav_a.txt", workbench.activeTab().?.input.getName());

    // Joining drops the split copy whose model is already open in the target.
    try workbench.joinAllGroups();
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
}

test "Workbench: sash drag resizes the split" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "sash_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "sash_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    workbench.setCellBorders(true);

    try std.testing.expectEqual(@as(usize, 25), ui.cell.snap(workbench.part.root.kind.split.first.rect.w));
    const boundary = ui.cell.snap(workbench.part.root.kind.split.first.rect.right());

    var down = ui.MouseEvent{ .kind = .down, .x = boundary, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&down));
    try std.testing.expect(workbench.part.active_sash != null);

    var move = ui.MouseEvent{ .kind = .move, .x = 30, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&move));
    try std.testing.expectEqual(@as(f64, 0.6), workbench.part.root.kind.split.ratio);
    try std.testing.expectEqual(@as(usize, 30), ui.cell.snap(workbench.part.root.kind.split.first.rect.w));

    var up = ui.MouseEvent{ .kind = .up, .x = 30, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&up));
    try std.testing.expect(workbench.part.active_sash == null);
}

test "Workbench: tabs and editor content resolve pointer shapes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "pointer_shape.txt", "abc");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 50, 10);
    defer workbench.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    const tab_x = pane.hits.items[0].start;
    const title_y = ui.cell.snap(pane.rect.y);

    workbench.beginMousePointer();
    var over_tab = ui.MouseEvent{ .kind = .move, .x = tab_x, .y = title_y };
    try std.testing.expect(workbench.handleTabMouse(&over_tab));
    try std.testing.expectEqual(ui.Pointer.pointer, workbench.pointerShape());

    workbench.beginMousePointer();
    var empty_strip = over_tab;
    empty_strip.x = ui.cell.snap(pane.rect.right()) - 1;
    try std.testing.expect(workbench.handleTabMouse(&empty_strip));
    try std.testing.expectEqual(ui.Pointer.default, workbench.pointerShape());

    workbench.beginMousePointer();
    const content = ui.MouseEvent{
        .kind = .move,
        .x = ui.cell.snap(pane.rect.x) + tab.editor.gutterWidth() + 1,
        .y = title_y + pane.chromeHeight(),
    };
    workbench.updateMousePointer(content);
    try std.testing.expectEqual(ui.Pointer.text, workbench.pointerShape());
}

test "Workbench: render emits OSC 22 only when the pointer changes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "pointer_render.txt", "abc");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 8);
    defer workbench.deinit();
    workbench.setPointerShapes(true);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // The initial default shape adds no bytes to the first frame.
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;") == null);

    out.clearRetainingCapacity();
    workbench.setPointer(.pointer);
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;pointer\x1b\\") != null);

    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;") == null);

    out.clearRetainingCapacity();
    workbench.setPointer(.default);
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;default\x1b\\") != null);
}

test "Workbench: closing the last tab collapses the empty group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "collapse_a.txt", "alpha");
    defer allocator.free(path_a);

    const workbench = try Workbench.init(allocator, io, &.{path_a}, 50, 10);
    defer workbench.deinit();
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.part.group_views.items.len);

    _ = try workbench.closeActive();
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 1), workbench.part.group_views.items.len);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqual(@as(usize, 50), ui.cell.snap(workbench.part.root.rect.w));
}

test "Workbench: dragging a tab into a pane moves it there" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "drag_move_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "drag_move_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const source = workbench.part.group_views.items[1];
    const target = workbench.part.group_views.items[0];
    const tab_x = source.hits.items[0].start;
    const tab_y = ui.cell.snap(source.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = tab_x, .y = tab_y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&down));

    var move = ui.MouseEvent{
        .kind = .move,
        .x = ui.cell.snap(target.rect.x) + ui.cell.snap(target.rect.w) / 2,
        .y = ui.cell.snap(target.rect.y) + ui.cell.snap(target.rect.h) / 2,
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&move));
    try std.testing.expect(workbench.editor_drag.active);

    var up = move;
    up.kind = .up;
    try std.testing.expect(workbench.handleTabDragMouse(&up));

    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 1), workbench.part.group_views.items.len);
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
}

test "Workbench: dragging over a tab strip previews the insertion and reorders on drop" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "strip_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "strip_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    workbench.setCellBorders(true);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    const tab_y = ui.cell.snap(pane.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = pane.hits.items[0].start, .y = tab_y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&down));

    // Right half of the second tab: insert after it, not a top-edge split.
    const second = pane.hits.items[1];
    var move = ui.MouseEvent{
        .kind = .move,
        .x = second.start + (second.end - second.start) / 2 + 1,
        .y = tab_y,
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&move));
    try std.testing.expect(workbench.editor_drag.active);
    try std.testing.expect(workbench.drag_target == null);
    try std.testing.expect(workbench.drag_tab_drop != null);
    try std.testing.expect(workbench.drag_tab_drop.?.pane == pane);
    try std.testing.expectEqual(@as(usize, 2), workbench.drag_tab_drop.?.index);

    // The strip paints upstream's drop-target-right line at the last tab edge.
    try workbench.render(&out.writer);
    const last = pane.hits.items[pane.hits.items.len - 1];
    const border = workbench.frame.prev.borderSetAt(last.end - 1, tab_y);
    try std.testing.expect(border.strokeAt(ui.cell_border.Segment.right) != null);

    var up = move;
    up.kind = .up;
    try std.testing.expect(workbench.handleTabDragMouse(&up));

    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    var ordered = std.array_list.Managed(*Tab).init(allocator);
    defer ordered.deinit();
    try pane.orderedTabs(allocator, &ordered);
    try std.testing.expectEqual(@as(usize, 2), ordered.items.len);
    try std.testing.expect(std.mem.endsWith(u8, ordered.items[0].editor.path, "strip_b.txt"));
    try std.testing.expect(std.mem.endsWith(u8, ordered.items[1].editor.path, "strip_a.txt"));
}

test "Workbench: dropping a tab on another strip inserts at the previewed index" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "strip_insert_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "strip_insert_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    // The source group starts with A and B; close B so moving A empties it.
    const source = workbench.part.group_views.items[0];
    const target = workbench.part.group_views.items[1];
    workbench.service.activateGroup(source.group);
    try source.activateTab(source.tabs.items[1]);
    _ = try workbench.closeActive();
    workbench.service.activateGroup(target.group);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const source_y = ui.cell.snap(source.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = source.hits.items[0].start, .y = source_y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&down));

    // The right half of the target's only tab inserts after it.
    const target_y = ui.cell.snap(target.rect.y);
    const target_hit = target.hits.items[0];
    var move = ui.MouseEvent{
        .kind = .move,
        .x = target_hit.end - 1,
        .y = target_y,
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&move));
    try std.testing.expect(workbench.drag_tab_drop != null);
    try std.testing.expect(workbench.drag_tab_drop.?.pane == target);
    try std.testing.expectEqual(@as(usize, 1), workbench.drag_tab_drop.?.index);

    var up = move;
    up.kind = .up;
    try std.testing.expect(workbench.handleTabDragMouse(&up));

    // The source group empties and collapses; the target keeps the insert order.
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    const remaining = workbench.part.group_views.items[0];
    var ordered = std.array_list.Managed(*Tab).init(allocator);
    defer ordered.deinit();
    try remaining.orderedTabs(allocator, &ordered);
    try std.testing.expectEqual(@as(usize, 2), ordered.items.len);
    try std.testing.expect(std.mem.endsWith(u8, ordered.items[0].editor.path, "strip_insert_b.txt"));
    try std.testing.expect(std.mem.endsWith(u8, ordered.items[1].editor.path, "strip_insert_a.txt"));
}

test "Workbench: editor drag moves, copies, and merges a whole group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try seedFile(allocator, io, &tmp, "a.txt", "alpha");
    defer allocator.free(a);
    const b = try seedFile(allocator, io, &tmp, "b.txt", "beta");
    defer allocator.free(b);
    const c = try seedFile(allocator, io, &tmp, "c.txt", "gamma");
    defer allocator.free(c);
    const workbench = try Workbench.init(allocator, io, &.{ a, b, c }, 120, 30);
    defer workbench.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const original = workbench.activePane().?;
    const y = ui.cell.snap(original.rect.y);
    const center_y = ui.cell.snap(original.rect.y + original.rect.h / 2);
    const far_right = ui.cell.snap(original.rect.right()) - 1;
    try sendDragMouse(workbench, 0, original.hits.items[0].start, y, false);
    try sendDragMouse(workbench, 32, far_right, center_y, false);
    try sendDragMouse(workbench, 0, far_right, center_y, true);
    const group = workbench.activePane().?;
    const id = group.group.id;
    const original_left = ui.cell.snap(original.rect.x);
    try workbench.render(&out.writer);

    try sendDragMouse(workbench, 0, ui.cell.snap(group.rect.right()) - 2, ui.cell.snap(group.rect.y), false);
    try sendDragMouse(workbench, 32, original_left, center_y, false);
    try std.testing.expect(workbench.editor_drag.source.?.tab == null);
    try sendDragMouse(workbench, 0, original_left, center_y, true);
    try std.testing.expectEqual(id, workbench.activePane().?.group.id);
    try std.testing.expect(group.rect.x < original.rect.x);
    try workbench.render(&out.writer);

    const copy_mod: usize = if (builtin.os.tag == .macos) 8 else 16;
    try sendDragMouse(workbench, 0, ui.cell.snap(group.rect.right()) - 2, ui.cell.snap(group.rect.y), false);
    try sendDragMouse(workbench, 32 + copy_mod, far_right, center_y, false);
    try sendDragMouse(workbench, copy_mod, far_right, center_y, true);
    const copied = workbench.activePane().?;
    try std.testing.expect(copied.group.id != id and copied != original);
    try std.testing.expectEqual(@as(usize, 3), workbench.groupCount());
    try std.testing.expect(copied.activeTab().?.editor.model == group.activeTab().?.editor.model);
    try workbench.render(&out.writer);

    const center_x = ui.cell.snap(original.rect.x + original.rect.w / 2);
    try sendDragMouse(workbench, 0, ui.cell.snap(copied.rect.right()) - 2, ui.cell.snap(copied.rect.y), false);
    try sendDragMouse(workbench, 32, center_x, center_y, false);
    try sendDragMouse(workbench, 0, center_x, center_y, true);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 3), original.tabs.items.len);
}

test "Workbench: editor drag opens the hovered tab only after its deadline" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try seedFile(allocator, io, &tmp, "a.txt", "alpha");
    defer allocator.free(a);
    const b = try seedFile(allocator, io, &tmp, "b.txt", "beta");
    defer allocator.free(b);
    const workbench = try Workbench.init(allocator, io, &.{ a, b }, 100, 20);
    defer workbench.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const pane = workbench.activePane().?;
    const y = ui.cell.snap(pane.rect.y);

    try sendDragMouse(workbench, 0, pane.hits.items[0].start, y, false);
    try sendDragMouse(workbench, 32, pane.hits.items[1].start, y, false);
    const hover = workbench.drag_hover orelse return error.MissingDragHover;
    const deadline = hover.deadline.?;
    try std.testing.expect(!workbench.tickEditorDrag(deadline - 1));
    try std.testing.expect(workbench.activeTab() != hover.tab);
    try std.testing.expect(workbench.tickEditorDrag(deadline));
    try std.testing.expect(workbench.activeTab() == hover.tab);
    try std.testing.expect(workbench.cancelEditorDrag());
    try std.testing.expect(workbench.drag_hover == null and workbench.drag_tab_drop == null);
}

test "Workbench: openPath reveals an already-open file in another group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "reveal_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "reveal_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);

    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqualStrings("reveal_b.txt", workbench.activeTab().?.input.getName());

    try workbench.openPath(path_a);
    // A + B in the source group and the split copy of B.
    try std.testing.expectEqual(@as(usize, 3), workbench.tabCount());
    try std.testing.expectEqualStrings("reveal_a.txt", workbench.activeTab().?.input.getName());
}

test "Workbench: serialize and restore a group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "restore_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "restore_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 9);
    defer workbench.deinit();
    try workbench.activateIndex(1);

    var serializer = workbench.createFileSerializer();
    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, serializer.interface());

    var data = try workbench.serialize(allocator, &registry);
    defer data.deinit(allocator);

    const restored = try Workbench.initFromSerialized(allocator, io, data, &registry, 60, 9);
    defer restored.deinit();

    try std.testing.expectEqual(@as(usize, 2), restored.tabCount());
    try std.testing.expectEqualStrings("restore_b.txt", restored.activeTab().?.input.getName());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try restored.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "restore_a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "restore_b.txt") != null);

    const Observer = struct {
        active: ?*EditorInput = null,

        fn changed(active: ?*EditorInput, state: *@This()) !void {
            state.active = active;
        }
    };
    var observer = Observer{};
    const listener = try restored.service.on_did_active_editor_change.listen(&observer, Observer.changed);
    defer restored.service.on_did_active_editor_change.unlisten(listener);
    try restored.activateIndex(0);
    try std.testing.expect(observer.active == restored.activeTab().?.input);
}

test "Workbench: serialize and restore multiple groups" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "part_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "part_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 70, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    var serializer = workbench.createFileSerializer();
    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, serializer.interface());

    var data = try workbench.serializePart(allocator, &registry);
    defer data.deinit(allocator);

    const restored = try Workbench.initFromSerializedPart(allocator, io, data, &registry, 70, 10);
    defer restored.deinit();

    try std.testing.expectEqual(@as(usize, 2), restored.groupCount());
    // Group one restores A + B and group two restores the split copy of B.
    try std.testing.expectEqual(@as(usize, 3), restored.tabCount());
    try std.testing.expectEqualStrings("part_b.txt", restored.activeTab().?.input.getName());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try restored.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "part_a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "part_b.txt") != null);
}

test "Workbench: sidebar renders and opens a file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "side_a.txt", "alpha");
    defer allocator.free(path_a);

    const workbench = try Workbench.init(allocator, io, &.{path_a}, 70, 12);
    defer workbench.deinit();

    // Put the sidebar at the temp root and create the file it should open.
    var sidebar_file = try tmp.dir.createFile(io, "side_open.txt", .{});
    try sidebar_file.writeStreamingAll(io, "opened from sidebar");
    sidebar_file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    workbench.focusSidebar();
    try std.testing.expect(workbench.part.group_views.items[0].rect.x > 0);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "EXPLORER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "side_open.txt") != null);

    const explorer_body = workbench.explorer_container.?.bodyRect("explorer").?;
    const click = ui.MouseEvent{ .kind = .down, .x = 4, .y = ui.cell.snap(explorer_body.y) + 1 };
    try std.testing.expect(workbench.handleSidebarMouse(&click));
    pumpOpenForTests(workbench);
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqualStrings("side_open.txt", workbench.activeTab().?.input.getName());
    try std.testing.expectEqual(Focus.editor, workbench.focus);

    const ctrl_b = ui.KeyEvent{ .key = .{ .char = 'b' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleSidebarKey(&ctrl_b));
    try std.testing.expect(!workbench.layout_model.isVisible(.sidebar));
    try std.testing.expect(try workbench.handleSidebarKey(&ctrl_b));
    try std.testing.expect(workbench.layout_model.isVisible(.sidebar));
}

test "Workbench: workspace search streams results and opens a match" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "search_me.txt", "alpha beta\ngamma alpha\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);

    try workbench.findInFiles();
    const view = workbench.search_view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    var guard: usize = 0;
    while ((view.model.isSearching() or view.wantsTick()) and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }
    try std.testing.expectEqual(@as(usize, 2), view.model.result.count());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "SEARCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2 results in 1 file") != null);
}

test "Workbench: opening a search match selects its range" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "open_me.txt", "alpha beta\ngamma alpha\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    var guard: usize = 0;
    while (view.model.isSearching() and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }
    try std.testing.expect(view.rows.items.len > 0);

    var match_row: ?usize = null;
    for (view.rows.items, 0..) |row, index| {
        switch (row) {
            .match => {
                match_row = index;
                break;
            },
            else => {},
        }
    }
    view.selected = match_row.?;
    view.results_focused = true;
    const enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expectEqual(@as(@TypeOf(view.handleKey(&enter)), .handled), view.handleKey(&enter));
    const tab = workbench.activeTab().?;
    const selections = try tab.editor.getSelections();
    defer allocator.free(selections);
    try std.testing.expectEqual(@as(usize, 1), selections.len);
    try std.testing.expectEqual(@as(usize, 1), selections[0].startLineNumber);
    try std.testing.expectEqual(@as(usize, 1), selections[0].startColumn);
    try std.testing.expectEqual(@as(usize, 1), selections[0].endLineNumber);
    try std.testing.expectEqual(@as(usize, 6), selections[0].endColumn);
}

test "Workbench: opening a search result from another file does not restart the query" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = try seedFile(allocator, io, &tmp, "first.txt", "alpha beta\n");
    defer allocator.free(first);
    const second = try seedFile(allocator, io, &tmp, "second.txt", "gamma alpha\n");
    defer allocator.free(second);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const second_resource = try std.fs.path.join(allocator, &.{ root, "second.txt" });
    defer allocator.free(second_resource);

    const workbench = try Workbench.init(allocator, io, &.{first}, 80, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    workbench.onSearchEditorChanged();
    try workbench.findInFiles();
    const view = workbench.search_view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    var guard: usize = 0;
    while (view.model.isSearching() and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }
    try std.testing.expectEqual(@as(usize, 2), view.model.result.count());

    var second_row: ?usize = null;
    for (view.rows.items, 0..) |row, index| {
        switch (row) {
            .match => |match| {
                if (std.mem.eql(u8, match.parent_file.path, second_resource)) {
                    second_row = index;
                    break;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(second_row != null);
    view.selected = second_row.?;
    view.results_focused = true;
    const enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expectEqual(@as(@TypeOf(view.handleKey(&enter)), .handled), view.handleKey(&enter));

    // The app reports the newly active editor after the click. Switching to
    // another file is not a content change, so it must not schedule a query.
    workbench.onSearchEditorChanged();
    _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp() + 600);
    try std.testing.expect(!view.model.isSearching());
    try std.testing.expectEqual(@as(usize, 2), view.model.result.count());
}

test "Workbench: search chevron and replace all confirmation update an open editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "replace_me.txt", "alpha beta\ngamma alpha\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);

    try workbench.findInFiles();
    const view = workbench.search_view.?;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const x = ui.cell.snap(view.last_rect.x);
    const y = ui.cell.snap(view.last_rect.y) + view.header_rows;
    const control = view.widget.controlRect(.toggle_replace).?;
    const down = ui.MouseEvent{
        .kind = .down,
        .button = .left,
        .x = x + ui.cell.snap(control.x),
        .y = y + ui.cell.snap(control.y),
    };
    try std.testing.expect(!view.widget.replace_visible);
    try std.testing.expect(workbench.handleSidebarMouse(&down));
    try std.testing.expect(view.widget.replace_visible);
    try view.widget.setValue(.search, "alpha");
    try view.widget.setValue(.replace, "omega");
    view.model.setReplaceString("omega") catch {};
    try view.startSearch();
    var guard: usize = 0;
    while (view.model.isSearching() and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }
    try std.testing.expectEqual(@as(usize, 2), view.model.result.count());
    try workbench.render(&out.writer);
    const replace_all = view.widget.controlRect(.replace_all).?;
    const click = ui.MouseEvent{
        .kind = .down,
        .button = .left,
        .x = x + ui.cell.snap(replace_all.x),
        .y = y + ui.cell.snap(replace_all.y),
    };
    try std.testing.expect(workbench.handleSidebarMouse(&click));
    try std.testing.expect(view.replace_confirmation != null);
    try std.testing.expectEqual(@as(usize, 2), view.matchCount());
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(workbench.handleDialogKey(&escape));
    try std.testing.expect(view.replace_confirmation == null);
    try std.testing.expect(workbench.handleSidebarMouse(&click));
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(workbench.handleDialogKey(&enter));

    const tab = workbench.activeTab().?;
    var content = try tab.editor.model.getValue(null, false);
    defer content.deinit();
    try std.testing.expect(std.mem.indexOf(u8, content.items, "omega beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, content.items, "gamma omega") != null);
}

test "Workbench: activity bar switches view containers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "activity.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 12);
    defer workbench.deinit();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    workbench.focusSidebar();

    const search_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 2 };
    try std.testing.expect(workbench.handleSidebarMouse(&search_click));
    try std.testing.expectEqual(@as(usize, 1), workbench.activeActivity());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "SEARCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "No results") != null or std.mem.indexOf(u8, out.written(), "Search") != null);

    const scm_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 3 };
    try std.testing.expect(workbench.handleSidebarMouse(&scm_click));
    try std.testing.expectEqual(@as(usize, 2), workbench.activeActivity());
    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Source Control") != null);

    // Upstream has no Settings view container: its activity bar gear is the
    // `workbench.actions.manage` global action that opens the Settings editor
    // as an editor tab, which is not ported. A click below the last entry
    // changes nothing.
    const empty_rail_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 4 };
    try std.testing.expect(workbench.handleSidebarMouse(&empty_rail_click));
    try std.testing.expectEqual(@as(usize, 2), workbench.activeActivity());
    try std.testing.expectEqual(@as(usize, 3), workbench.activity_bar_part.count());

    // Problems is a panel container: no activity-bar entry and no sidebar
    // container (upstream registers it in `ViewContainerLocation.Panel`).
    try std.testing.expect(!try workbench.showActivityById("problems"));
    try std.testing.expect(!workbench.panelShown());

    const alt_1 = ui.KeyEvent{ .key = .{ .char = '1' }, .mods = .{ .alt = true } };
    try std.testing.expect(try workbench.handleSidebarKey(&alt_1));
    try std.testing.expectEqual(@as(usize, 0), workbench.activeActivity());
}

test "Workbench: zen mode restores a status bar that was hidden before" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "zen_status.txt", "alpha\n");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 70, 12);
    defer workbench.deinit();
    try workbench.layout_model.setVisible(.statusbar, false);
    try std.testing.expect(!workbench.statusBarVisible());

    try workbench.toggleZenMode(false, false);
    try std.testing.expect(!workbench.statusBarVisible());
    try workbench.toggleZenMode(false, false);
    try std.testing.expect(!workbench.layout_model.isZenModeActive());
    try std.testing.expect(!workbench.statusBarVisible());
}

test "Workbench: zen tab actions are only available in zen mode" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var settings_file = try tmp.dir.createFile(io, "zen-action-settings.json", .{});
    try settings_file.writeStreamingAll(io, "{}");
    settings_file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/zen-action-settings.json", .{buffer[0..root_len]});
    defer allocator.free(settings_path);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    workbench.ensureConfigurationReady();

    const hide = workbench.commands.get(zen_mode_contribution.zen_hide_editor_tabs_id).?;
    const multiple = workbench.commands.get(zen_mode_contribution.zen_show_multiple_editor_tabs_id).?;
    const single = workbench.commands.get(zen_mode_contribution.zen_show_single_editor_tab_id).?;
    try std.testing.expect(!hide.precondition.?(hide.context));
    try std.testing.expect(!multiple.precondition.?(multiple.context));
    try std.testing.expect(!single.precondition.?(single.context));

    try workbench.toggleZenMode(false, false);
    try std.testing.expect(hide.precondition.?(hide.context));
    try std.testing.expect(!multiple.precondition.?(multiple.context));
    try std.testing.expect(single.precondition.?(single.context));

    try workbench.commands.execute(zen_mode_contribution.zen_hide_editor_tabs_id);
    try std.testing.expect(!hide.precondition.?(hide.context));
    try std.testing.expect(multiple.precondition.?(multiple.context));
    try std.testing.expect(single.precondition.?(single.context));

    try workbench.commands.execute(zen_mode_contribution.zen_show_single_editor_tab_id);
    try std.testing.expect(hide.precondition.?(hide.context));
    try std.testing.expect(multiple.precondition.?(multiple.context));
    try std.testing.expect(!single.precondition.?(single.context));
}

test "Workbench: zen mode keybindings toggle and exit" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();

    const ctrl_k = ui.KeyEvent{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_k));
    const z = ui.KeyEvent{ .key = .{ .char = 'z' } };
    try std.testing.expect(try workbench.handleGlobalKey(&z));
    try std.testing.expect(workbench.layout_model.isZenModeActive());

    const escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(try workbench.handleGlobalKey(&escape));
    try std.testing.expect(try workbench.handleGlobalKey(&escape));
    try std.testing.expect(!workbench.layout_model.isZenModeActive());
}

test "Workbench: Problems panel, status count and range highlight" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "diag.txt", "one\ntwo\nthree");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 100, 16);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.enableLanguageFeatures();
    const service = workbench.marker_service orelse return error.TestUnexpectedResult;

    const tab = workbench.activeTab() orelse return error.TestExpectedTab;
    var resource = markers_mod.Resource.fromUri(allocator, tab.editor.model.uri()) catch return error.TestUnexpectedResult;
    defer resource.deinit(allocator);
    try service.changeOne("test", resource, &.{
        .{
            .severity = markers_mod.MarkerSeverity.Error,
            .message = "boom",
            .start_line_number = 2,
            .start_column = 1,
            .end_line_number = 2,
            .end_column = 4,
        },
    }, null);

    const status = workbench.statusbar.main_part.model.findEntry("status.problems") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, status.item.text(), "1") != null);

    try workbench.showProblems();
    try std.testing.expect(workbench.panelShown());
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.activePanelId());
    try std.testing.expectEqual(Focus.problems, workbench.focus);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "PROBLEMS") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "diag.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "boom") != null);
    try std.testing.expect(workbench.range_highlights.?.highlighted);

    const enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try workbench.handlePanelKey(&enter));
    try std.testing.expectEqual(@as(usize, 2), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
    try std.testing.expect(!workbench.range_highlights.?.highlighted);
}

test "Workbench: panel composite bar hosts Problems beside the Terminal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "panel.txt", "one\ntwo");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 90, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.enableLanguageFeatures();
    try std.testing.expect(!workbench.panelShown());

    const service = workbench.marker_service orelse return error.TestUnexpectedResult;
    const tab = workbench.activeTab() orelse return error.TestExpectedTab;
    var resource = markers_mod.Resource.fromUri(allocator, tab.editor.model.uri()) catch return error.TestUnexpectedResult;
    defer resource.deinit(allocator);
    try service.changeOne("test", resource, &.{
        .{
            .severity = markers_mod.MarkerSeverity.Warning,
            .message = "careful",
            .start_line_number = 1,
            .start_column = 1,
            .end_line_number = 1,
            .end_column = 2,
        },
    }, null);

    // Markers alone do not reveal the panel, but they do publish the
    // `hideIfEmpty` Problems title; the Problems command opens the panel.
    try std.testing.expect(!workbench.panelShown());
    try std.testing.expect(workbench.panel_part.pane.bar.findItemConst(PROBLEMS_CONTAINER_ID).?.visible);
    try workbench.showProblems();
    try std.testing.expect(workbench.panelShown());
    try std.testing.expect(workbench.panel_part.pane.bar.findItemConst(PROBLEMS_CONTAINER_ID).?.visible);

    // Toggling Problems while it owns focus hides the panel; toggling again
    // reveals the same container.
    try workbench.toggleProblems();
    try std.testing.expect(!workbench.panelShown());
    try workbench.toggleProblems();
    try std.testing.expect(workbench.panelShown());
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.activePanelId());

    // Ctrl-J closes and re-opens the panel with its last active container.
    const ctrl_j = ui.KeyEvent{ .key = .{ .char = 'j' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_j));
    try std.testing.expect(!workbench.panelShown());
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_j));
    try std.testing.expect(workbench.panelShown());

    // Ctrl-Shift-M toggles Problems through the registered keybinding.
    const ctrl_shift_m = ui.KeyEvent{ .key = .{ .char = 'm' }, .mods = .{ .ctrl = true, .shift = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_shift_m));
    try std.testing.expect(!workbench.panelShown());
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_shift_m));
    try std.testing.expect(workbench.panelShown());
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.activePanelId());

    // The Terminal container shares the panel title; upstream order puts
    // Problems (order 0) before Terminal (order 3).
    const terminal_service = try TerminalService.init(allocator, io, .{ .launch = launchTestTerminal });
    workbench.terminal_service = terminal_service;
    workbench.newTerminal() catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqualStrings(TERMINAL_CONTAINER_ID, workbench.activePanelId());
    try std.testing.expect(workbench.terminalVisible());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const problems_index = std.mem.indexOf(u8, out.written(), "PROBLEMS") orelse return error.TestUnexpectedResult;
    const terminal_index = std.mem.indexOf(u8, out.written(), "TERMINAL") orelse return error.TestUnexpectedResult;
    try std.testing.expect(problems_index < terminal_index);

    // Clearing the markers drops the inactive Problems title again while the
    // panel and the Terminal tab stay.
    try service.changeOne("test", resource, &.{}, null);
    try std.testing.expect(!workbench.panel_part.pane.bar.findItemConst(PROBLEMS_CONTAINER_ID).?.visible);
    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "TERMINAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "PROBLEMS") == null);
}

test "Workbench: opens a folder workspace with no initial tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "folder_file.txt", .{});
    try file.writeStreamingAll(io, "from folder");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 12);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.initSidebarFromWorkspace();
    pumpSidebarForTests(workbench);
    workbench.focusSidebar();

    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());
    try std.testing.expect(workbench.activeTab() == null);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "EXPLORER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "folder_file.txt") != null);

    const explorer_body = workbench.explorer_container.?.bodyRect("explorer").?;
    const click = ui.MouseEvent{ .kind = .down, .x = 4, .y = ui.cell.snap(explorer_body.y) };
    try std.testing.expect(workbench.handleSidebarMouse(&click));
    pumpOpenForTests(workbench);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("folder_file.txt", workbench.activeTab().?.input.getName());
}

test "Workbench: Ctrl-P opens a file and Alt-P runs a command" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    var file = try tmp.dir.createFile(io, "src/alpha.txt", .{});
    try file.writeStreamingAll(io, "alpha");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleQuickAccessKey(&ctrl_p));
    try std.testing.expect(workbench.isQuickAccessOpen());

    const picker = workbench.quick_access.controller.pickerRef();
    try picker.setValue("alp");
    var guard: usize = 0;
    while (workbench.quickAccessWantsTick() and guard < 2000) : (guard += 1) {
        _ = try workbench.pollQuickAccess(0);
    }
    try std.testing.expectEqualStrings("alpha.txt", picker.activeItem().?.label);

    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expect(!workbench.isQuickAccessOpen());
    var open_guard: usize = 0;
    while (workbench.tabCount() == 0 and open_guard < 2000) : (open_guard += 1) {
        _ = workbench.pollAsyncReads();
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("alpha.txt", workbench.activeTab().?.input.getName());
    try std.testing.expectEqual(@as(usize, 1), workbench.history.getHistory().len);

    // Alt-P opens the command palette directly; "split" runs the split command.
    var alt_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .alt = true } };
    try std.testing.expect(try workbench.handleQuickAccessKey(&alt_p));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try picker.setValue(">split");
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
}

test "Workbench: opening a file reveals it in the Explorer" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    var file = try tmp.dir.createFile(io, "src/revealed.txt", .{});
    try file.writeStreamingAll(io, "revealed");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/src/revealed.txt", .{root});
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.openPath(path);
    pumpSidebarForTests(workbench);

    const selected = workbench.sidebar.?.selectedNode().?;
    try std.testing.expectEqualStrings("revealed.txt", selected.name);
    try std.testing.expect(workbench.sidebar.?.isExpanded(selected.parent.?));
}

test "Workbench: explorer.autoReveal false disables selection" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    var settings = try tmp.dir.createFile(io, ".vscode/settings.json", .{});
    try settings.writeStreamingAll(io, "{\"explorer.autoReveal\": false}");
    settings.close(io);
    var file = try tmp.dir.createFile(io, "no_reveal.txt", .{});
    try file.writeStreamingAll(io, "x");
    file.close(io);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const path = try std.fmt.allocPrint(allocator, "{s}/no_reveal.txt", .{root});
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.openPath(path);
    pumpSidebarForTests(workbench);

    const selected = workbench.sidebar.?.selectedNode().?;
    try std.testing.expect(!std.mem.eql(u8, selected.name, "no_reveal.txt"));
}

test "Workbench: switching tabs reveals the active file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var a = try tmp.dir.createFile(io, "a.txt", .{});
    try a.writeStreamingAll(io, "a");
    a.close(io);
    var b = try tmp.dir.createFile(io, "b.txt", .{});
    try b.writeStreamingAll(io, "b");
    b.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const path_a = try std.fmt.allocPrint(allocator, "{s}/a.txt", .{root});
    defer allocator.free(path_a);
    const path_b = try std.fmt.allocPrint(allocator, "{s}/b.txt", .{root});
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.openPath(path_a);
    try workbench.openPath(path_b);
    try std.testing.expectEqualStrings("b.txt", workbench.sidebar.?.selectedNode().?.name);

    try workbench.switchTab(-1);
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.getName());
    try std.testing.expectEqualStrings("a.txt", workbench.sidebar.?.selectedNode().?.name);
}

test "Workbench: quick access row buttons open to the side, configure shortcuts and remove history" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try seedFile(allocator, io, &tmp, "CPU.hs", "");
    defer allocator.free(file);
    const bindings = try seedFile(allocator, io, &tmp, "keybindings.json",
        \\[{"key":"ctrl+alt+b","command":"workbench.action.splitEditor"}]
    );
    defer allocator.free(bindings);
    const workbench = try Workbench.init(allocator, io, &.{}, 90, 24);
    defer workbench.deinit();
    try workbench.setKeybindingsPaths(&.{bindings});
    try workbench.openPath(file);
    const quick = workbench.quick_access;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try quick.showFilePicker();
    try workbench.render(&out.writer);
    const layout = quick.widget.layout;
    const right = layout.x + layout.width - layout.inset - 1;
    var click = ui.MouseEvent{ .kind = .down, .button = .left, .x = right - 5, .y = layout.y + layout.inset + 1 };
    try std.testing.expect(workbench.handleQuickAccessMouse(&click));
    try std.testing.expect(!quick.isOpen());
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqualStrings("CPU.hs", workbench.activeTab().?.input.getName());

    try quick.showFilePicker();
    try workbench.render(&out.writer);
    click.x = right - 2;
    try std.testing.expect(workbench.handleQuickAccessMouse(&click));
    try std.testing.expect(quick.isOpen());
    try std.testing.expectEqual(@as(usize, 0), workbench.history.getHistory().len);
    try std.testing.expectEqual(@as(usize, 0), quick.controller.pickerRef().rows.items.len);

    const command = "workbench.action.splitEditor";
    try quick.commands_provider.base.history.push(command);
    try quick.showCommandPicker();
    const picker = quick.controller.pickerRef();
    try picker.setValue(">" ++ command);
    try workbench.render(&out.writer);
    const keys = picker.activeItem().?.keycaps;
    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqualStrings("Ctrl", keys[0]);
    try std.testing.expectEqualStrings("Alt", keys[1]);
    try std.testing.expectEqualStrings("B", keys[2]);
    try std.testing.expect(workbench.handleQuickAccessMouse(&click));
    try std.testing.expect(quick.isOpen());
    try std.testing.expectEqual(@as(?usize, null), quick.commands_provider.base.history.rank(command));
    try workbench.render(&out.writer);
    var tab_key = ui.KeyEvent{ .key = .tab };
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try workbench.handleQuickAccessKey(&tab_key));
    try std.testing.expect(try workbench.handleQuickAccessKey(&enter));
    try std.testing.expect(!quick.isOpen());
    try std.testing.expectEqualStrings("keybindings.json", workbench.activeTab().?.input.getName());
    try std.testing.expectEqualStrings(command, workbench.activeTab().?.controllers.?.find.state.search_string);
}

test "Workbench: quick open renders and an outside click only closes it" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "outside.txt", .{});
    try file.writeStreamingAll(io, "outside");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{}, 60, 10);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleQuickAccessKey(&ctrl_p));

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Search files") != null);

    var click = ui.MouseEvent{ .kind = .down, .x = 0, .y = 9 };
    try std.testing.expect(workbench.handleQuickAccessMouse(&click));
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());
}

test "Workbench: list keybindings route to the focused sidebar" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var file_a = try tmp.dir.createFile(io, "a.txt", .{});
    try file_a.writeStreamingAll(io, "a");
    file_a.close(io);
    var file_b = try tmp.dir.createFile(io, "b.txt", .{});
    try file_b.writeStreamingAll(io, "b");
    file_b.close(io);

    const keybindings_path = try std.fmt.allocPrint(allocator, "{s}/list-keybindings.json", .{root});
    defer allocator.free(keybindings_path);
    var keybindings = try std.Io.Dir.cwd().createFile(io, keybindings_path, .{});
    try keybindings.writeStreamingAll(io,
        \\[ { "key": "j", "command": "list.focusDown", "when": "listFocus" } ]
    );
    keybindings.close(io);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.initSidebarFromWorkspace();
    pumpSidebarForTests(workbench);
    try workbench.setKeybindingsPaths(&.{keybindings_path});

    var j = ui.KeyEvent{ .key = .{ .char = 'j' } };
    // The binding is gated by `listFocus`; the editor does not match it.
    workbench.focusEditor();
    try std.testing.expect(!(try workbench.handleGlobalKey(&j)));
    workbench.focusSidebar();
    try std.testing.expect(try workbench.handleGlobalKey(&j));
}

test "Workbench: color theme settings load a registered theme palette" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var theme_file = try tmp.dir.createFile(io, "theme.json", .{});
    try theme_file.writeStreamingAll(io,
        \\{ "colors": { "editor.background": "#ffffff", "editor.foreground": "#101010", "statusBar.background": "#eeeeee" } }
    );
    theme_file.close(io);
    var settings_file = try tmp.dir.createFile(io, "settings.json", .{});
    try settings_file.writeStreamingAll(io,
        \\{ "workbench.colorTheme": "Test Theme" }
    );
    settings_file.close(io);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = try allocator.dupe(u8, buffer[0..root_len]);
    defer allocator.free(root);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{root});
    defer allocator.free(settings_path);

    const workbench = try Workbench.init(allocator, io, &.{}, 60, 12);
    defer workbench.deinit();
    try workbench.registerThemeSources(&.{
        .{
            .root = root,
            .id = "Test Theme",
            .settings_id = "Test Theme",
            .label = "Test Theme",
            .ui_theme = "vs",
            .path = "theme.json",
        },
    });
    try workbench.setUserSettingsPaths(&.{settings_path});
    workbench.applyThemeSettings();

    const service = workbench.theme_service.?;
    try std.testing.expectEqualStrings("Test Theme", service.getActiveThemeId());
    const palette = workbench.theme_palette.?;
    try std.testing.expectEqual(@as(u8, 0xff), palette.background.r);
    try std.testing.expectEqual(@as(u8, 0x10), palette.foreground.g);
    const status = palette.color("statusBar.background", .{ 0, 0, 0 });
    try std.testing.expectEqual(@as(u8, 0xee), status.r);
}

test "Workbench: opening a themed file initializes the editor controllers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "themed.txt", "themed");
    defer allocator.free(path);

    var theme_file = try tmp.dir.createFile(io, "theme.json", .{});
    try theme_file.writeStreamingAll(io,
        \\{ "colors": { "editor.background": "#101010", "editor.foreground": "#e0e0e0" } }
    );
    theme_file.close(io);
    var settings_file = try tmp.dir.createFile(io, "settings.json", .{});
    try settings_file.writeStreamingAll(io,
        \\{ "workbench.colorTheme": "Test Theme" }
    );
    settings_file.close(io);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = try allocator.dupe(u8, buffer[0..root_len]);
    defer allocator.free(root);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{root});
    defer allocator.free(settings_path);

    const workbench = try Workbench.init(allocator, io, &.{}, 60, 12);
    defer workbench.deinit();
    try workbench.registerThemeSources(&.{
        .{
            .root = root,
            .id = "Test Theme",
            .settings_id = "Test Theme",
            .label = "Test Theme",
            .ui_theme = "vs",
            .path = "theme.json",
        },
    });
    try workbench.setUserSettingsPaths(&.{settings_path});
    workbench.applyThemeSettings();
    try std.testing.expect(workbench.theme_palette != null);

    // `openPath` applies the palette to the new view and then initializes its
    // controllers; the suggest/hover widgets must already exist by that point.
    try workbench.openPath(path);
    try std.testing.expect(workbench.activeTab().?.controllers != null);
}

test "Workbench: Preferences JSON commands create and open the TUI layer" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/config/settings.json", .{buffer[0..root_len]});
    defer allocator.free(settings_path);
    const keybindings_path = try std.fmt.allocPrint(allocator, "{s}/config/keybindings.json", .{buffer[0..root_len]});
    defer allocator.free(keybindings_path);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.setKeybindingsPaths(&.{keybindings_path});

    try workbench.commands.execute("workbench.action.openSettingsJson");
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("settings.json", workbench.activeTab().?.input.getName());
    var settings_content = try workbench.activeTab().?.editor.model.getValue(.TextDefined, false);
    defer settings_content.deinit();
    try std.testing.expectEqualStrings("{\n}\n", settings_content.items);

    try workbench.commands.execute("workbench.action.openGlobalKeybindingsFile");
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqualStrings("keybindings.json", workbench.activeTab().?.input.getName());
    var keybindings_content = try workbench.activeTab().?.editor.model.getValue(.TextDefined, false);
    defer keybindings_content.deinit();
    try std.testing.expectEqualStrings("[\n]\n", keybindings_content.items);
}

test "Workbench: user keybindings override defaults, honor when and removals" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const keybindings_path = try std.fmt.allocPrint(allocator, "{s}/keybindings.json", .{buffer[0..root_len]});
    defer allocator.free(keybindings_path);

    try writeKeybindingsFile(&tmp, io, keybindings_path, allocator,
        \\[
        \\  { "key": "ctrl+alt+g", "command": "workbench.action.showCommands" },
        \\  { "key": "ctrl+b", "command": "workbench.action.showCommands" },
        \\  { "key": "ctrl+alt+n", "command": "workbench.action.showCommands", "when": "editorTextFocus" },
        \\  { "key": "ctrl+alt+m", "command": "workbench.action.showCommands", "when": "!editorTextFocus" },
        \\  { "key": "ctrl+alt+u", "command": "no.such.command" },
        \\  { "command": "-workbench.action.toggleSidebarVisibility" }
        \\]
    );

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.setKeybindingsPaths(&.{keybindings_path});
    workbench.focusEditor();

    const ctrl_alt_g = ui.KeyEvent{ .key = .{ .char = 'g' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_alt_g));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try closeQuickAccess(workbench);

    // A user binding with the same chord as a default wins.
    var ctrl_b = ui.KeyEvent{ .key = .{ .char = 'b' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_b));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try closeQuickAccess(workbench);

    // `when` clauses use the shared context keys.
    const ctrl_alt_n = ui.KeyEvent{ .key = .{ .char = 'n' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_alt_n));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try closeQuickAccess(workbench);
    const ctrl_alt_m = ui.KeyEvent{ .key = .{ .char = 'm' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(!(try workbench.handleGlobalKey(&ctrl_alt_m)));
    try std.testing.expect(!workbench.isQuickAccessOpen());

    // Unknown commands are filtered so they cannot swallow typing.
    const ctrl_alt_u = ui.KeyEvent{ .key = .{ .char = 'u' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(!(try workbench.handleGlobalKey(&ctrl_alt_u)));

    // Reloading applies removals: Ctrl+B no longer resolves globally.
    try writeKeybindingsFile(&tmp, io, keybindings_path, allocator,
        \\[
        \\  { "command": "-workbench.action.toggleSidebarVisibility" }
        \\]
    );
    try workbench.setKeybindingsPaths(&.{keybindings_path});
    try std.testing.expect(!(try workbench.handleGlobalKey(&ctrl_b)));
    try std.testing.expect(!(try workbench.handleGlobalKey(&ctrl_alt_g)));
}

test "Workbench: editor settings apply to open editors and reload" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "settings_editor.txt", "alpha beta\nbeta\n");
    defer allocator.free(path);
    var settings_file = try tmp.dir.createFile(io, "editor-settings.json", .{});
    try settings_file.writeStreamingAll(io, "{\"editor.lineNumbers\":\"relative\",\"editor.renderWhitespace\":\"all\",\"editor.matchBrackets\":\"never\"}");
    settings_file.close(io);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/editor-settings.json", .{buffer[0..root_len]});
    defer allocator.free(settings_path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});

    const tab = workbench.activeTab().?;
    try std.testing.expectEqual(
        editor_options.RenderLineNumbersType.Relative,
        tab.view.terminal_view_host.options.get(.lineNumbers).render_type,
    );
    try std.testing.expectEqual(
        editor_options.RenderWhitespace.all,
        tab.view.terminal_view_host.options.get(.renderWhitespace),
    );
    try std.testing.expectEqual(
        editor_options.MatchBrackets.never,
        tab.view.terminal_view_host.options.get(.matchBrackets),
    );

    // The settings change must reach the view-line options, not just the
    // computed-options store: the open editor renders middle dots for spaces.
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try workbench.render(&rendered.writer);
    const frame = try frameText(allocator, &workbench.frame);
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\u{00B7}") != null);

    // Editing the file and re-applying the layer updates the open editor.
    var reloaded_settings = try tmp.dir.createFile(io, "editor-settings.json", .{ .truncate = true });
    try reloaded_settings.writeStreamingAll(io, "{\"editor.lineNumbers\":\"off\"}");
    reloaded_settings.close(io);
    try workbench.setUserSettingsPaths(&.{settings_path});
    try std.testing.expectEqual(
        editor_options.RenderLineNumbersType.Off,
        tab.view.terminal_view_host.options.get(.lineNumbers).render_type,
    );
}

test "Workbench: search shows no-results and honors showLineNumbers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "settings_search.txt", "prefix alpha beta\n");
    defer allocator.free(path);
    var settings_file = try tmp.dir.createFile(io, "search-settings.json", .{});
    try settings_file.writeStreamingAll(io, "{\"search.showLineNumbers\": true}");
    settings_file.close(io);
    var settings_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const settings_dir_len = try tmp.dir.realPath(io, &settings_buffer);
    const settings_path = try std.fs.path.join(allocator, &.{ settings_buffer[0..settings_dir_len], "search-settings.json" });
    defer allocator.free(settings_path);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_view.?;

    try view.widget.setValue(.search, "zzz-not-found");
    try view.startSearch();
    var guard: usize = 0;
    while ((view.wantsTick() or view.model.isSearching()) and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "No results found") != null);

    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    guard = 0;
    while ((view.wantsTick() or view.model.isSearching()) and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try workbench.render(&rendered.writer);
    const grid = workbench.frame.present();
    const y = ui.cell.snap(view.last_rect.y) + view.results_y + 1;
    const row = try grid.rowText(allocator, y);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "1: prefix alpha beta") != null);
    const col = ui.cell.snap(view.last_rect.x) + @import("../vs/workbench/contrib/search/browser/searchResultsView.zig").matchIndentCells(1) + 3;
    const before = y * grid.cols + col;
    const match = before + "prefix ".len;
    const after = match + "alpha ".len;
    try std.testing.expectEqual(grid.fg[before], grid.fg[after]);
    try std.testing.expectEqual(grid.bg[before], grid.bg[after]);
    try std.testing.expect(grid.bg[before] != grid.bg[match]);
}

test "Workbench: search editor shows query controls and reruns with independent context" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try seedFile(allocator, io, &tmp, "test.txt", "before\nalpha\nbetween\nbeta\nafter\n");
    defer allocator.free(source);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{source}, 95, 25);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const sidebar = workbench.search_view.?;
    try sidebar.widget.setValue(.search, "alpha");
    try sidebar.startSearch();
    const wait = struct {
        fn run(owner: *Workbench) !void {
            var guard: usize = 0;
            while (owner.searchWantsTick() and guard < 1000) : (guard += 1) {
                _ = owner.pollSearch(@import("../vs/base/common/timeCompat.zig").milliTimestamp() + 1000);
            }
            try std.testing.expect(!owner.searchWantsTick());
        }
    }.run;
    try wait(workbench);
    try sidebar.openInEditor();
    try wait(workbench);
    const tab = workbench.activeTab().?;
    const input = tab.search_editor_input.?;
    const query = input.search_editor;
    workbench.onSearchEditorChanged();
    try std.testing.expectEqualStrings("alpha", query.form.value(.search));
    try std.testing.expectEqual(@as(usize, 1), query.form.contextLines());

    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try workbench.render(&rendered.writer);
    try std.testing.expect(query.form.controlRect(.toggle_replace) == null);
    try std.testing.expect(query.form.controlRect(.context_lines) != null);
    try std.testing.expect(workbench.activePane().?.breadcrumbs_suppressed);
    var first = try tab.editor.model.getValue(null, false);
    defer first.deinit();
    try std.testing.expect(std.mem.indexOf(u8, first.items, "  1  before\n  2: alpha\n  3  between") != null);

    const pane = workbench.activePane().?;
    tab.editor.refreshFoldingIfDirty();
    const fold_click = ui.MouseEvent{
        .kind = .down,
        .button = .left,
        .x = ui.cell.snap(pane.rect.x) + tab.editor.foldCellColumn(),
        .y = ui.cell.snap(pane.rect.y) + pane.chromeHeight() + query.headerRows() + 2,
    };
    for ([_]bool{ false, true }) |visible| {
        try std.testing.expect(!workbench.handleSearchEditorMouse(&fold_click));
        var target = workbench.editorMouseEvent(fold_click).?;
        try std.testing.expect(try target.tab.view.dispatchMouse(&target.event));
        try std.testing.expectEqual(visible, tab.editor.isModelLineVisible(4));
        try workbench.render(&rendered.writer);
    }
    try std.testing.expect(workbench.activeTab() == tab);
    query.query_focused = true;

    try query.form.setValue(.search, "beta");
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(workbench.handleSearchEditorKey(&enter));
    try wait(workbench);
    try std.testing.expect(workbench.activeTab() == tab);
    try std.testing.expectEqualStrings("Search: beta", input.base.getName());
    try std.testing.expectEqualStrings("alpha", sidebar.widget.value(.search));
    var second = try tab.editor.model.getValue(null, false);
    defer second.deinit();
    try std.testing.expect(std.mem.indexOf(u8, second.items, "  3  between\n  4: beta\n  5  after") != null);

    const toggle = query.form.controlRect(.toggle_context).?;
    try std.testing.expect(workbench.handleSearchEditorMouse(&.{
        .kind = .down,
        .button = .left,
        .x = ui.cell.snap(pane.rect.x + toggle.x),
        .y = ui.cell.snap(pane.rect.y + toggle.y) + pane.chromeHeight(),
    }));
    try wait(workbench);
    var no_context = try tab.editor.model.getValue(null, false);
    defer no_context.deinit();
    try std.testing.expect(std.mem.indexOf(u8, no_context.items, "  4: beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_context.items, "between") == null);

    query.form.setDetailsVisible(true);
    try workbench.render(&rendered.writer);
    query.form.focusField(.includes);
    try query.form.setValue(.includes, "*.zig");
    try std.testing.expect(workbench.handleSearchEditorKey(&enter));
    try wait(workbench);
    try workbench.render(&rendered.writer);
    tab.view.invalidate();
    try workbench.render(&rendered.writer);
    const results_y = ui.cell.snap(pane.rect.y) + pane.chromeHeight() + query.headerRows();
    const no_results_row = try workbench.frame.present().rowText(allocator, results_y);
    defer allocator.free(no_results_row);
    try std.testing.expect(std.mem.indexOf(u8, no_results_row, "No Results") != null);
    try query.form.setValue(.includes, "");
    try std.testing.expect(workbench.handleSearchEditorKey(&enter));
    try wait(workbench);

    query.query_focused = false;
    try tab.editor.setCursorPosition(.{ .lineNumber = 4, .column = 6 });
    try std.testing.expect(workbench.handleSearchEditorKey(&enter));
    try std.testing.expect(workbench.activeTab() != tab);
    try std.testing.expectEqual(@as(usize, 4), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);

    try workbench.switchTab(1);
    try std.testing.expect(workbench.activeTab() == tab);
    query.query_focused = true;
    query.form.focusField(.search);
    workbench.onSearchEditorChanged();
    try query.form.setValue(.search, "");
    try std.testing.expect(workbench.handleSearchEditorKey(&enter));
    try wait(workbench);
    workbench.onSearchEditorChanged();
    try std.testing.expect(sidebar.controller.refresh_at == null);
    try std.testing.expectEqualStrings("alpha", sidebar.widget.value(.search));
    try std.testing.expectEqual(@as(usize, 1), sidebar.matchCount());
}

test "Workbench: typing a search query restarts results without stale collapse keys" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "typed_search.txt", "test tester testing\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_view.?;

    for ([_][]const u8{ "t", "te", "tes", "test" }) |query| {
        try view.widget.setValue(.search, query);
        try view.startSearch();
        var guard: usize = 0;
        while ((view.wantsTick() or view.model.isSearching()) and guard < 100) : (guard += 1) {
            _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
        }
    }

    var saw_file = false;
    var saw_match = false;
    for (view.rows.items, view.depths.items) |row, depth| {
        switch (row) {
            .file => {
                saw_file = true;
                // List mode places files at the root; only tree mode nests them.
                try std.testing.expectEqual(@as(usize, 0), depth);
            },
            .match => {
                saw_match = true;
                try std.testing.expectEqual(@as(usize, 1), depth);
            },
            else => {},
        }
    }
    try std.testing.expect(saw_file);
    try std.testing.expect(saw_match);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "test") != null);
}

test "Workbench: wheel scrolls search results without moving the selection" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }
    for (0..14) |index| {
        var name_buffer: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "scroll_{d}.txt", .{index});
        const path = try seedFile(allocator, io, &tmp, name, "alpha\n");
        try paths.append(path);
    }
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, paths.items, 80, 16);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    var guard: usize = 0;
    while ((view.wantsTick() or view.model.isSearching()) and guard < 100) : (guard += 1) {
        _ = view.tick(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(view.rows.items.len > view.visible_rows);

    const selected_before = view.selected;
    const scroll_before = view.scroll;
    const x = ui.cell.snap(view.last_rect.x) + 2;
    const y = ui.cell.snap(view.last_rect.y) + view.results_y + 1;
    const wheel = ui.MouseEvent{ .kind = .wheel, .x = x, .y = y, .delta_y = 1 };
    try std.testing.expect(workbench.handleSidebarMouse(&wheel));
    try std.testing.expect(view.scroll > scroll_before);
    try std.testing.expectEqual(selected_before, view.selected);

    var after: std.Io.Writer.Allocating = .init(allocator);
    defer after.deinit();
    try workbench.render(&after.writer);
    try std.testing.expect(view.scroll > scroll_before);
}

test "Workbench: search input focus follows presses, not hover" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "search_focus.txt", "alpha\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 16);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_view.?;
    view.focusReplace();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(view.panel_focused);
    try std.testing.expectEqual(search_widget_mod.Field.replace, view.widget.focus_field);
    try std.testing.expect(!view.widget.search.focused);
    try std.testing.expect(view.widget.replace.focused);

    // Idle mode-1003 motion over the search row is hover only: the replace
    // field keeps the caret and panel focus does not change.
    const x = ui.cell.snap(view.last_rect.x) + 2;
    const y = ui.cell.snap(view.last_rect.y) + view.header_rows + view.widget.layout.search_y;
    var hover = ui.MouseEvent{ .kind = .move, .x = x, .y = y };
    try std.testing.expect(workbench.handleSidebarMouse(&hover));
    try std.testing.expect(view.panel_focused);
    try std.testing.expectEqual(search_widget_mod.Field.replace, view.widget.focus_field);
    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(!view.widget.search.focused);
    try std.testing.expect(view.widget.replace.focused);

    // A press does move focus and the caret.
    var down = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleSidebarMouse(&down));
    try std.testing.expectEqual(search_widget_mod.Field.search, view.widget.focus_field);
    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(view.widget.search.focused);
    try std.testing.expect(!view.widget.replace.focused);

    // Leaving the side bar clears the visual focus as well as the controller
    // flag, so the caret does not keep looking focused behind the editor.
    workbench.focusEditor();
    out.clearRetainingCapacity();
    try workbench.render(&out.writer);
    try std.testing.expect(!view.panel_focused);
    try std.testing.expect(!view.widget.search.focused);
    try std.testing.expect(!view.widget.replace.focused);
}

test "Workbench: status bar context menu hides an entry" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "status_menu.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();

    const model = &workbench.statusbar.main_part.model;
    const entry = if (model.findEntry("status.editor.mode")) |found| found else &model.entries()[0];
    const id = entry.id;
    try workbench.showStatusbarContextMenu(entry.handle, &.{ .kind = .down, .button = .right, .x = 4, .y = 11 });
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expect(workbench.context_menu != null);
    for (workbench.context_menu.?.popup.?.items) |item| {
        if (item.type == .checkbox) try std.testing.expect(item.label.len > 0);
    }
    try std.testing.expect(workbench.handleContextMenuKey(&.{ .key = .end }));
    try std.testing.expect(std.mem.startsWith(u8, workbench.context_menu.?.popup.?.focusedItem().?.label, "Hide"));

    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.handleContextMenuKey(&enter);
    try std.testing.expect(model.isHidden(id));
}

test "Workbench: duplicate tab labels show their directories" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "a/same.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "b/same.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 80, 10);
    defer workbench.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    const row = try workbench.frame.prev.rowText(allocator, ui.cell.snap(pane.rect.y));
    defer allocator.free(row);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, row, "same.txt"));
    try std.testing.expect(std.mem.indexOf(u8, row, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "b") != null);
}

test "Workbench: status bar spans the window and shows editor state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "status.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 120, 10);
    defer workbench.deinit();

    try std.testing.expect(workbench.statusBarVisible());
    try std.testing.expectEqual(@as(usize, 9), ui.cell.snap(workbench.statusBarRect().y));

    const pane = workbench.part.group_views.items[0];
    try std.testing.expectEqual(@as(usize, 9), ui.cell.snap(pane.rect.h));
    try std.testing.expectEqual(@as(usize, 7), workbench.activeTab().?.editor.screen_height);

    workbench.refreshStatus();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const status = try workbench.frame.prev.rowText(allocator, 9);
    defer allocator.free(status);
    // The status bar mirrors VS Code: no quit hint is rendered.
    try std.testing.expect(std.mem.indexOf(u8, status, "Ctrl-Q") == null);
    try std.testing.expect(std.mem.indexOf(u8, status, "status.txt") == null);
    try std.testing.expect(std.mem.indexOf(u8, status, "Ln 1, Col 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "Spaces: 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "LF") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "UTF-8") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "Plain Text") != null);

    workbench.focusStatusBar();
    try std.testing.expectEqual(Focus.statusbar, workbench.focus);
    try std.testing.expect(workbench.statusbar.main_part.focusedHandle() != null);
    try std.testing.expect(workbench.cursorCell() == null);

    const right = ui.KeyEvent{ .key = .right };
    try std.testing.expect(try workbench.handleStatusbarKey(&right));
    const escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(try workbench.handleStatusbarKey(&escape));
    try std.testing.expect(workbench.statusbar.main_part.focusedHandle() == null);
    try std.testing.expect(try workbench.handleStatusbarKey(&escape));
    try std.testing.expectEqual(Focus.editor, workbench.focus);
}

test "Workbench: Ctrl-Alt-S toggles status bar focus" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "focus.txt", "x");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 8);
    defer workbench.deinit();

    const toggle = ui.KeyEvent{ .key = .{ .char = 's' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(try workbench.handleStatusbarKey(&toggle));
    try std.testing.expectEqual(Focus.statusbar, workbench.focus);
    try std.testing.expect(try workbench.handleStatusbarKey(&toggle));
    try std.testing.expectEqual(Focus.editor, workbench.focus);
}

test "Workbench: clicking a status entry focuses it and runs its command" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "click.txt", "x");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 100, 8);
    defer workbench.deinit();

    const State = struct {
        hits: usize = 0,
        fn run(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.hits += 1;
        }
    };
    var state = State{};
    try workbench.commands.register(.{
        .id = "test.statusbar.command",
        .label = "Status Command",
        .context = &state,
        .run = State.run,
    });
    const accessor = try workbench.statusbar.addEntry(.{
        .name = "Status command",
        .text = "CMD",
        .command = .{ .id = "test.statusbar.command" },
    }, "test.statusbar.command", .right, .{ .number = 50 });

    workbench.refreshStatus();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const y = ui.cell.snap(workbench.statusBarRect().y);
    var hit_x: ?usize = null;
    var x: usize = 0;
    while (x < 100) : (x += 1) {
        const hit = workbench.statusbar.main_part.hitAt(x, y) catch null;
        if (hit) |value| {
            switch (value) {
                .entry => |handle| if (handle == accessor.handle) {
                    hit_x = x;
                    break;
                },
                .part => {},
            }
        }
    }
    const click_x = hit_x orelse return error.StatusEntryNotFound;
    var click = ui.MouseEvent{ .kind = .down, .x = click_x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleStatusbarMouse(&click));
    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expectEqual(Focus.statusbar, workbench.focus);
    try std.testing.expectEqual(accessor.handle, workbench.statusbar.main_part.focusedHandle().?);
}

test "Workbench: status values open the matching pickers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "pick.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 120, 10);
    defer workbench.deinit();
    workbench.refreshStatus();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.indentation"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqualStrings("Indent Using Spaces", workbench.quick_access.inputService().pickerRef().activeItem().?.label);
    var escape = ui.KeyEvent{ .key = .escape };
    _ = try workbench.handleQuickAccessKey(&escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.encoding"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqualStrings("UTF-8", workbench.quick_access.inputService().pickerRef().activeItem().?.label);
    _ = try workbench.handleQuickAccessKey(&escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.eol"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqualStrings("LF", workbench.quick_access.inputService().pickerRef().activeItem().?.label);
    _ = try workbench.handleQuickAccessKey(&escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.mode"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    _ = try workbench.handleQuickAccessKey(&escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.selection"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqual(@as(usize, 0), workbench.quick_access.inputService().pickerRef().items.items.len);
    _ = try workbench.handleQuickAccessKey(&escape);
    try std.testing.expect(!workbench.quick_access.isOpen());
}

test "Workbench: EOL and language pickers update the editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "pick-actions.txt", "alpha\nbeta\ngamma");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 120, 10);
    defer workbench.deinit();
    workbench.refreshStatus();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.encoding"));
    var down = ui.KeyEvent{ .key = .down };
    _ = try workbench.handleQuickAccessKey(&down);
    var enter = ui.KeyEvent{ .key = .enter };
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expectEqual(
        encoding_mod.Encoding.utf8_with_bom,
        workbench.activeTab().?.editor.getEncoding(),
    );
    try std.testing.expectEqualStrings(
        "UTF-8 with BOM",
        workbench.statusbar.main_part.model.findEntry("status.editor.encoding").?.item.text(),
    );

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.eol"));
    _ = try workbench.handleQuickAccessKey(&down);
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expect(!workbench.quick_access.isOpen());
    try std.testing.expectEqual(EOL.CRLF, workbench.activeTab().?.editor.model.getEOL());
    try std.testing.expectEqualStrings(
        "CRLF",
        workbench.statusbar.main_part.model.findEntry("status.editor.eol").?.item.text(),
    );

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.mode"));
    for ("zig") |ch| {
        var typed = ui.KeyEvent{ .key = .{ .char = ch } };
        _ = try workbench.handleQuickAccessKey(&typed);
    }
    try std.testing.expectEqualStrings("zig", workbench.quick_access.inputService().pickerRef().activeItem().?.id);
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expectEqualStrings("zig", workbench.activeTab().?.editor.languageId());
    try std.testing.expectEqualStrings(
        "Zig",
        workbench.statusbar.main_part.model.findEntry("status.editor.mode").?.item.text(),
    );

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.selection"));
    for ("2:3") |ch| {
        var typed = ui.KeyEvent{ .key = .{ .char = ch } };
        _ = try workbench.handleQuickAccessKey(&typed);
    }
    _ = try workbench.handleQuickAccessKey(&enter);
    const selections = try workbench.activeTab().?.editor.getSelections();
    defer allocator.free(selections);
    try std.testing.expectEqual(@as(usize, 2), selections[0].startLineNumber);
    try std.testing.expectEqual(@as(usize, 3), selections[0].startColumn);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.indentation"));
    _ = try workbench.handleQuickAccessKey(&down);
    _ = try workbench.handleQuickAccessKey(&enter);
    try std.testing.expect(!workbench.activeTab().?.editor.model.getOptions().insertSpaces);
    try std.testing.expectEqualStrings(
        "Tab Size: 4",
        workbench.statusbar.main_part.model.findEntry("status.editor.indentation").?.item.text(),
    );
}

test "workbench: global shortcuts dispatch through the keybinding registry" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&ctrl_p));
    try std.testing.expect(workbench.isQuickAccessOpen());

    // While quick access owns the keyboard the global host steps aside.
    try std.testing.expect(!(try workbench.handleGlobalKey(&ctrl_p)));
}

test "Workbench: files.associations change the opened editor language" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var settings_file = try tmp.dir.createFile(io, "settings.json", .{});
    try settings_file.writeStreamingAll(io, "{\"files.associations\":{\"*.custom\":\"zig\"}}");
    settings_file.close(io);
    var settings_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const settings_dir_len = try tmp.dir.realPath(io, &settings_buffer);
    const settings_path = try std.fs.path.join(allocator, &.{ settings_buffer[0..settings_dir_len], "settings.json" });
    defer allocator.free(settings_path);

    const path = try seedFile(allocator, io, &tmp, "sample.custom", "body");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 9);
    defer workbench.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.openPath(path);

    try std.testing.expectEqualStrings("zig", workbench.activeTab().?.editor.languageId());
}

test "Workbench: starts a workspace file watcher for absolute folders" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 9);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try std.testing.expect(workbench.workspace_watcher == null);
    try workbench.runContributionPhase(.after_restored);
    try std.testing.expect(workbench.workspace_watcher != null);
    try std.testing.expect(workbench.file_watcher_service != null);
}

test "Workbench: workspace watcher honors watcherExclude and watcherInclude" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    var settings = try tmp.dir.createFile(io, ".vscode/settings.json", .{});
    try settings.writeStreamingAll(
        io,
        "{\"files.watcherExclude\": {\"ignored/**\": true}, \"files.watcherInclude\": [\"included\"]}",
    );
    settings.close(io);
    try tmp.dir.createDirPath(io, "ignored");
    try tmp.dir.createDirPath(io, "included");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.runContributionPhase(.after_restored);

    const service = workbench.file_watcher_service.?;
    const included = try std.fs.path.join(allocator, &.{ root, "included" });
    defer allocator.free(included);

    var found_root = false;
    var found_included = false;
    var index: usize = 0;
    while (index < service.watchedCount()) : (index += 1) {
        const path = service.watchedPathAt(index) orelse continue;
        if (std.mem.eql(u8, path, root)) {
            found_root = true;
            const excludes = service.watchedExcludesAt(index) orelse &.{};
            var has_custom = false;
            var has_default = false;
            for (excludes) |exclude| {
                if (std.mem.eql(u8, exclude, "ignored/**")) has_custom = true;
                if (std.mem.eql(u8, exclude, ".git/objects/**")) has_default = true;
            }
            try std.testing.expect(has_custom);
            try std.testing.expect(has_default);
        }
        if (std.mem.eql(u8, path, included)) found_included = true;
    }
    try std.testing.expect(found_root);
    try std.testing.expect(found_included);
}

test "Workbench: AfterRestored watcher reloads a clean editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "watched.txt", "before");
    defer allocator.free(path);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    const tab = workbench.activeTab().?;

    try workbench.setWorkspaceFolders(&.{root});
    try workbench.runContributionPhase(.after_restored);
    const service = workbench.file_watcher_service.?;

    const ready_deadline = time_compat.milliTimestamp() + 3000;
    while (time_compat.milliTimestamp() < ready_deadline and !service.isReady()) {
        _ = workbench.pollFileWatcher(time_compat.milliTimestamp());
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(service.isReady());

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "after" });

    const deadline = time_compat.milliTimestamp() + 3000;
    var reloaded = false;
    while (time_compat.milliTimestamp() < deadline and !reloaded) {
        _ = workbench.pollFileWatcher(time_compat.milliTimestamp());
        var value = tab.editor.model.getValue(.TextDefined, true) catch break;
        reloaded = std.mem.eql(u8, value.items, "after");
        value.deinit();
        if (!reloaded) io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(reloaded);
}

test "Workbench: revert command discards edits and clears conflicts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "revert.txt", "on disk");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    const tab = workbench.activeTab().?;

    try tab.editor.insertText("local ");
    try std.testing.expect(tab.editor.isDirty());
    tab.editor.markConflict();

    try workbench.commands.execute("workbench.action.files.revert");
    var text = try tab.editor.model.getValue(.TextDefined, true);
    defer text.deinit();
    try std.testing.expectEqualStrings("on disk", text.items);
    try std.testing.expect(!tab.editor.isDirty());
    try std.testing.expect(!tab.editor.hasConflict());
}

test "Workbench: working copy service tracks dirty editors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "working-copy.txt", "content");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    const service = workbench.workingCopyService();
    try std.testing.expectEqual(@as(usize, 0), service.dirtyCount());
    try std.testing.expect(service.hasResource(path));

    const tab = workbench.activeTab().?;
    try tab.editor.insertText("X");
    try std.testing.expectEqual(@as(usize, 1), service.dirtyCount());
    try std.testing.expect(service.isDirty(path, null));

    try tab.editor.save();
    try std.testing.expectEqual(@as(usize, 0), service.dirtyCount());
    try std.testing.expect(!service.isDirty(path, null));

    _ = try workbench.closeActive();
    try std.testing.expect(!service.hasResource(path));
}

test "Workbench: decoded divider drag resizes the split" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "sash_decoded_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "sash_decoded_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const first = workbench.part.root.kind.split.first;
    try std.testing.expect(!workbench.part.cell_borders);
    const boundary = ui.cell.snap(first.rect.right());
    try std.testing.expectEqual(@as(usize, 24), boundary);

    // Press on the gutter divider, drag it six cells right and release.
    var buf: [160]u8 = undefined;
    const seq = try std.fmt.bufPrint(
        &buf,
        "\x1b[<0;{d};3M\x1b[<32;{d};3M\x1b[<0;{d};3m",
        .{ boundary + 1, boundary + 7, boundary + 7 },
    );
    var items = try ui.input.decode(allocator, seq);
    defer items.deinit(allocator);
    for (items.items) |*item| {
        switch (item.*) {
            .key, .focus => return error.TestUnexpectedResult,
            .mouse => |*mouse| {
                if (workbench.handleTabDragMouse(mouse)) continue;
                if (workbench.handleQuickAccessMouse(mouse)) continue;
                if (workbench.handleStatusbarMouse(mouse)) continue;
                if (workbench.handleSashMouse(mouse)) continue;
            },
        }
    }

    try std.testing.expectEqual(@as(f64, 30.0 / 49.0), workbench.part.root.kind.split.ratio);
    try std.testing.expectEqual(@as(usize, 30), ui.cell.snap(first.rect.w));
    try std.testing.expect(workbench.part.active_sash == null);
}

test "Workbench: sash follows drag motion without button bits" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "sash_buttonless_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "sash_buttonless_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const first = workbench.part.root.kind.split.first;
    const boundary = ui.cell.snap(first.rect.right());

    var down = ui.MouseEvent{ .kind = .down, .x = boundary, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&down));
    try std.testing.expect(workbench.part.active_sash != null);

    // Mode 1003 terminals may report drag motion with button `none`; the
    // grabbed sash still follows the pointer instead of ending the drag.
    var move = ui.MouseEvent{ .kind = .move, .x = boundary + 6, .y = 2, .button = .none };
    try std.testing.expect(workbench.handleSashMouse(&move));
    try std.testing.expect(workbench.part.active_sash != null);
    try std.testing.expectEqual(@as(f64, 30.0 / 49.0), workbench.part.root.kind.split.ratio);

    var up = ui.MouseEvent{ .kind = .up, .x = boundary + 6, .y = 2, .button = .left };
    try std.testing.expect(workbench.handleSashMouse(&up));
    try std.testing.expect(workbench.part.active_sash == null);
}

test "Workbench: decoded divider drag resizes a vertical split" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "sash_vertical_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "sash_vertical_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 14);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.vertical);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const first = workbench.part.root.kind.split.first;
    try std.testing.expectEqual(@as(usize, 6), ui.cell.snap(first.rect.bottom()));

    var buf: [160]u8 = undefined;
    const seq = try std.fmt.bufPrint(&buf, "\x1b[<0;3;7M\x1b[<32;3;10M\x1b[<0;3;10m", .{});
    var items = try ui.input.decode(allocator, seq);
    defer items.deinit(allocator);
    for (items.items) |*item| {
        switch (item.*) {
            .key, .focus => return error.TestUnexpectedResult,
            .mouse => |*mouse| {
                if (workbench.handleTabDragMouse(mouse)) continue;
                if (workbench.handleQuickAccessMouse(mouse)) continue;
                if (workbench.handleStatusbarMouse(mouse)) continue;
                if (workbench.handleSashMouse(mouse)) continue;
            },
        }
    }

    try std.testing.expectEqual(@as(f64, 9.0 / 12.0), workbench.part.root.kind.split.ratio);
    try std.testing.expectEqual(@as(usize, 9), ui.cell.snap(first.rect.h));
}

test "Workbench: tab context menu closes the tab" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "menu_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "menu_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expect(workbench.context_menu != null);
    try std.testing.expect(workbench.handleContextMenuKey(&.{ .key = .home }));
    try std.testing.expectEqualStrings("Close", workbench.context_menu.?.popup.?.focusedItem().?.label);

    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.handleContextMenuKey(&enter);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
}

test "Workbench: breadcrumb row shows the workspace-relative path" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "crumbs/src/http-proxy.js", "function parseAuthority() {}");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/crumbs", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{}, 60, 10);
    defer workbench.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.openPath(path);
    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    try std.testing.expectEqual(@as(usize, 2), pane.chromeHeight());
    const row = try workbench.frame.prev.rowText(allocator, 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "src") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "http-proxy.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, ">") != null);
    try std.testing.expectEqual(@as(usize, 2), workbench.cursorCell().?.row);

    // The first breadcrumb item opens the folder picker.
    const control = workbench.breadcrumbs_control.?;
    try std.testing.expect(control.widget.itemCount() >= 2);

    // The tab header and the breadcrumb file segment use the Explorer's icon.
    const expected_icon = file_icon.file("http-proxy.js");
    const tab_row = ui.cell.snap(pane.rect.y);
    const tab_icon_cell = pane.hits.items[0].start + 1;
    try std.testing.expectEqual(
        @as(u32, expected_icon.glyph),
        workbench.frame.prev.cluster[workbench.frame.prev.index(tab_icon_cell, tab_row)],
    );
    try std.testing.expectEqual(
        ui.cell.packColor(expected_icon.color),
        workbench.frame.prev.fg[workbench.frame.prev.index(tab_icon_cell, tab_row)],
    );
    const file_item = control.widget.items.items[control.widget.itemCount() - 1];
    const breadcrumb_icon = switch (file_item.icon) {
        .glyph => |glyph| glyph,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(expected_icon.glyph, breadcrumb_icon.codepoint);
    try std.testing.expectEqual(expected_icon.color, breadcrumb_icon.color);

    const hit = control.widget.hits.items[0];
    var click = ui.MouseEvent{ .kind = .down, .x = hit.start, .y = 1, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&click));
    try std.testing.expect(!workbench.quick_access.inputService().isVisible());
    try std.testing.expect(workbench.breadcrumbPopupVisible());
    try std.testing.expect(workbench.breadcrumb_popup.?.file != null);
    const picker = workbench.breadcrumb_popup.?.file.?;
    try std.testing.expect(picker.selectedPath() != null);
    const rounded = ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,outside,radius\x1b\\").?;
    for ([_]?ui.cell_border.Capabilities{ null, rounded }) |caps| {
        workbench.setCellBorderCapabilities(caps);
        try workbench.render(&out.writer);
        const left = ui.cell.snap(picker.rect.x);
        const right = ui.cell.snap(picker.rect.right()) - 1;
        const top = ui.cell.snap(picker.rect.y);
        const bottom = ui.cell.snap(picker.rect.bottom()) - 1;
        const cells = &workbench.frame.prev;
        const top_edge = cells.cluster[cells.index(left + 1, top)..cells.index(right, top)];
        try std.testing.expect(std.mem.indexOfScalar(u32, top_edge, '▲') == null);
        if (caps != null) {
            const joint = ui.cell_border.Joint;
            try std.testing.expectEqual(joint.top_left, cells.borderSetAt(left, top).joints);
            try std.testing.expectEqual(joint.top_right, cells.borderSetAt(right, top).joints);
            try std.testing.expectEqual(joint.bottom_left, cells.borderSetAt(left, bottom).joints);
            try std.testing.expectEqual(joint.bottom_right, cells.borderSetAt(right, bottom).joints);
        } else {
            try std.testing.expectEqual(@as(u32, '╭'), cells.cluster[cells.index(left, top)]);
            try std.testing.expectEqual(@as(u32, '╮'), cells.cluster[cells.index(right, top)]);
            try std.testing.expectEqual(@as(u32, '╰'), cells.cluster[cells.index(left, bottom)]);
            try std.testing.expectEqual(@as(u32, '╯'), cells.cluster[cells.index(right, bottom)]);
        }
    }
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(workbench.handleBreadcrumbPopupKey(&escape));
    try std.testing.expect(!workbench.breadcrumbPopupVisible());
}

test "Workbench: breadcrumb symbols come from a registered outline provider" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "symbols/file.ts", "class A {}");
    defer allocator.free(path);

    const Fake = struct {
        var labels = [_][]const u8{ "parseAuthority", "port" };
        var elements: [2]outline_mod.OutlineElement = undefined;
        var outline: outline_mod.IOutline = undefined;

        fn matches(_: *anyopaque, _: OutlineEditor) bool {
            return true;
        }
        fn create(_: *anyopaque, _: OutlineEditor, _: outline_mod.OutlineTarget) !?*outline_mod.IOutline {
            return &outline;
        }
        fn getElements(_: *anyopaque) []const outline_mod.OutlineElement {
            return &elements;
        }
        fn reveal(_: *anyopaque, _: *anyopaque, _: outline_mod.RevealOptions) !void {}
        fn dispose(_: *anyopaque) void {}
    };
    var context: u8 = 0;
    Fake.elements[0] = .{ .element = @ptrCast(@constCast(&Fake.labels[0])), .label = Fake.labels[0] };
    Fake.elements[1] = .{ .element = @ptrCast(@constCast(&Fake.labels[1])), .label = Fake.labels[1] };
    Fake.outline = .{
        .context = @ptrCast(&context),
        .uri = path,
        .outline_kind = "test",
        .config = .{ .breadcrumbs_data_source = .{
            .context = @ptrCast(&context),
            .get_breadcrumb_elements = Fake.getElements,
        } },
        .on_did_change = null,
        .revealFn = Fake.reveal,
        .disposeFn = Fake.dispose,
    };

    const workbench = try Workbench.init(allocator, io, &.{}, 60, 10);
    defer workbench.deinit();
    const registration = try workbench.outline_service.registerOutlineCreator(.{
        .context = @ptrCast(&context),
        .matches = Fake.matches,
        .create_outline = Fake.create,
    });
    defer registration.dispose();
    try workbench.openPath(path);
    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const row = try workbench.frame.prev.rowText(allocator, 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "parseAuthority") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "port") != null);
}

test "Workbench: closing a dirty tab asks, cancel keeps it and save closes it" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "close.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    try workbench.activeTab().?.ensureControllers();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    const hit = pane.hits.items[0];
    var click = ui.MouseEvent{
        .kind = .down,
        .x = hit.close_start.?,
        .y = ui.cell.snap(pane.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&click));
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    // A dirty tab opens the save confirmation instead of closing.
    try workbench.openPath(path);
    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("x");
    try workbench.render(&out.writer);
    const pane2 = workbench.activePane().?;
    var click2 = ui.MouseEvent{
        .kind = .down,
        .x = pane2.hits.items[0].close_start.?,
        .y = ui.cell.snap(pane2.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&click2));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(workbench.isDialogOpen());

    try workbench.render(&out.writer);
    const dialog_text = try frameText(allocator, &workbench.frame);
    defer allocator.free(dialog_text);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Do you want to save the changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "close.txt?") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Your changes will be lost") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Don't Save") != null);

    // Escape cancels the close and leaves the buffer dirty.
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(workbench.handleDialogKey(&escape));
    try std.testing.expect(!workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());

    // Enter activates the focused primary button, saves, then closes.
    try workbench.render(&out.writer);
    const pane3 = workbench.activePane().?;
    var click3 = ui.MouseEvent{
        .kind = .down,
        .x = pane3.hits.items[0].close_start.?,
        .y = ui.cell.snap(pane3.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&click3));
    try std.testing.expect(workbench.isDialogOpen());
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(workbench.handleDialogKey(&enter));
    try std.testing.expect(!workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    const saved = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024));
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("xalpha", saved);
}

test "Workbench: don't save closes a dirty tab without writing" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "discard.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("local ");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const pane = workbench.activePane().?;
    var click = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].close_start.?,
        .y = ui.cell.snap(pane.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&click));
    try std.testing.expect(workbench.isDialogOpen());

    var down = ui.KeyEvent{ .key = .down };
    try std.testing.expect(workbench.handleDialogKey(&down));
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(workbench.handleDialogKey(&enter));
    try std.testing.expect(!workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    const unchanged = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024));
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("alpha", unchanged);
}

test "Workbench: Ctrl-W on a dirty tab opens the save confirmation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "ctrl-w.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("x");

    var ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expect(workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());

    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(workbench.handleDialogKey(&escape));
    try std.testing.expect(!workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
}

test "Workbench: Ctrl-Q quits clean and confirms one dirty tab" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "quit_one.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    try workbench.activeTab().?.ensureControllers();

    // A clean workbench closes the window immediately.
    try std.testing.expect(workbench.requestQuit());
    try std.testing.expect(!workbench.isDialogOpen());

    try workbench.activeTab().?.editor.insertText("x");
    try std.testing.expect(!workbench.requestQuit());
    try std.testing.expect(workbench.isDialogOpen());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const dialog_text = try frameText(allocator, &workbench.frame);
    defer allocator.free(dialog_text);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Do you want to save the changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "quit_one.txt?") != null);

    // Cancel keeps the window and the dirty tab.
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(workbench.handleDialogKey(&escape));
    try std.testing.expect(!workbench.shouldQuit());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());

    // Save All saves the dirty tab, closes the window and lets the host exit.
    try std.testing.expect(!workbench.requestQuit());
    try std.testing.expect(workbench.isDialogOpen());
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(workbench.handleDialogKey(&enter));
    try std.testing.expect(!workbench.isDialogOpen());
    try std.testing.expect(workbench.shouldQuit());
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    const saved = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024));
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("xalpha", saved);
}

test "Workbench: Ctrl-Q lists every dirty tab and don't save closes all" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "quit_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "quit_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 20);
    defer workbench.deinit();
    try workbench.activateIndex(0);
    try workbench.activeTab().?.editor.insertText("a");
    try workbench.activateIndex(1);
    try workbench.activeTab().?.editor.insertText("b");

    try std.testing.expect(!workbench.requestQuit());
    try std.testing.expect(workbench.isDialogOpen());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const dialog_text = try frameText(allocator, &workbench.frame);
    defer allocator.free(dialog_text);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "following 2 files?") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "quit_a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "quit_b.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Save All") != null);

    // Down moves focus to Don't Save; Enter discards both tabs and quits.
    var down = ui.KeyEvent{ .key = .down };
    try std.testing.expect(workbench.handleDialogKey(&down));
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(workbench.handleDialogKey(&enter));
    try std.testing.expect(workbench.shouldQuit());
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    const saved_a = try Io.Dir.cwd().readFileAlloc(io, path_a, allocator, .limited(1024));
    defer allocator.free(saved_a);
    const saved_b = try Io.Dir.cwd().readFileAlloc(io, path_b, allocator, .limited(1024));
    defer allocator.free(saved_b);
    try std.testing.expectEqualStrings("alpha", saved_a);
    try std.testing.expectEqualStrings("beta", saved_b);
}

test "Workbench: preview replacement and dirty pin" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "preview_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "preview_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 9);
    defer workbench.deinit();
    try workbench.openPreviewPath(path_a);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(!workbench.activePane().?.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));

    try workbench.openPreviewPath(path_b);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(std.mem.endsWith(u8, workbench.activeTab().?.editor.path, "preview_b.txt"));

    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("x");
    workbench.refreshStatus();
    try std.testing.expect(workbench.activePane().?.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));

    try workbench.openPreviewPath(path_a);
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
}

test "Workbench: disabling breadcrumbs removes the row and shifts content" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var settings_file = try tmp.dir.createFile(io, "settings.json", .{});
    try settings_file.writeStreamingAll(io, "{\"breadcrumbs.enabled\":false}");
    settings_file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &buffer);
    const settings_path = try std.fs.path.join(allocator, &.{ buffer[0..dir_len], "settings.json" });
    defer allocator.free(settings_path);

    const path = try seedFile(allocator, io, &tmp, "no_crumbs.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 9);
    defer workbench.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.activeTab().?.ensureControllers();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    try std.testing.expectEqual(@as(usize, 1), pane.chromeHeight());
    try std.testing.expectEqual(@as(usize, 1), workbench.cursorCell().?.row);
}

test "Workbench: double click pins a preview tab and toggles a pinned group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "dblclick.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 10);
    defer workbench.deinit();
    try workbench.openPreviewPath(path);
    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    const hit = pane.hits.items[0];
    const x = hit.start + 1;
    const y = ui.cell.snap(pane.rect.y);
    var first = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&first));
    try std.testing.expect(!pane.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));
    // A real terminal also delivers the release between the two presses.
    var up = ui.MouseEvent{ .kind = .up, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&up));
    // Simulate a slow second click caused by the first activation's work.
    workbench.last_tab_click.?.at_ms -= 700;
    var second = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&second));
    try std.testing.expect(pane.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));
    try std.testing.expect(workbench.expanded_pane == null);

    // The UI repaints the now-pinned label without italics.
    try workbench.render(&out.writer);
    const hit_after = pane.hits.items[0];
    var col = hit_after.start;
    while (col < hit_after.end) : (col += 1) {
        try std.testing.expect(grid_attr_italic(&workbench.frame.prev, col, y) == false);
    }

    // A second double click on the now-pinned tab expands the group.
    var third = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&third));
    var fourth = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&fourth));
    try std.testing.expect(workbench.expanded_pane == pane);

    // And another double click restores the split layout.
    try workbench.render(&out.writer);
    var fifth = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&fifth));
    var sixth = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&sixth));
    try std.testing.expect(workbench.expanded_pane == null);
}

test "Workbench: double click still pins after a jittery drag starts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "jitter.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 10);
    defer workbench.deinit();
    try workbench.openPreviewPath(path);
    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.activePane().?;
    const hit = pane.hits.items[0];
    const x = hit.start + 1;
    const y = ui.cell.snap(pane.rect.y);
    var first = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabMouse(&first));

    // Hand jitter turns the pending click into a drag before the second press.
    var jitter = ui.MouseEvent{ .kind = .move, .x = x + 3, .y = y, .button = .left };
    try std.testing.expect(workbench.handleTabDragMouse(&jitter));
    try std.testing.expect(workbench.editor_drag.active);

    var second = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(!workbench.handleTabDragMouse(&second));
    try std.testing.expect(workbench.handleTabMouse(&second));
    try std.testing.expect(pane.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));
}

test "Workbench: LSP navigation, references and symbol picker" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "lsp/sample.ts",
        \\const value = 1;
        \\value;
        \\value;
    );
    defer allocator.free(path);

    const Fake = struct {
        fn definition(_: *anyopaque, allocator_: Allocator, model: *@import("../vs/editor/common/model/textModel.zig").TextModel, _: Position, _: CancellationToken) ![]languages.LocationLink {
            const uri = try std_uri.resourceKey(allocator_, model.uri());
            const links = try allocator_.alloc(languages.LocationLink, 1);
            const range = Range.init(2, 1, 2, 6);
            links[0] = .{ .uri = uri, .range = range, .target_selection_range = range };
            return links;
        }
        fn references(_: *anyopaque, allocator_: Allocator, model: *@import("../vs/editor/common/model/textModel.zig").TextModel, _: Position, _: languages.ReferenceContext, _: CancellationToken) ![]languages.Location {
            const uri = try std_uri.resourceKey(allocator_, model.uri());
            const locations = try allocator_.alloc(languages.Location, 2);
            locations[0] = .{ .uri = try allocator_.dupe(u8, uri), .range = Range.init(1, 1, 1, 6) };
            locations[1] = .{ .uri = try allocator_.dupe(u8, uri), .range = Range.init(2, 1, 2, 6) };
            allocator_.free(uri);
            return locations;
        }
        fn symbols(_: *anyopaque, allocator_: Allocator, model: *@import("../vs/editor/common/model/textModel.zig").TextModel, _: CancellationToken) ![]languages.DocumentSymbol {
            _ = model;
            const result = try allocator_.alloc(languages.DocumentSymbol, 1);
            result[0] = .{
                .name = try allocator_.dupe(u8, "value"),
                .kind = 13,
                .range = Range.init(1, 1, 3, 6),
                .selection_range = Range.init(2, 1, 2, 6),
            };
            return result;
        }
    };

    const workbench = try Workbench.init(allocator, io, &.{path}, 80, 20);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();
    const features = workbench.language_features.?;
    var context: u8 = 0;
    const definition_registration = try features.definition_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_definition = Fake.definition,
    });
    defer definition_registration.dispose();
    const reference_registration = try features.reference_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_references = Fake.references,
    });
    defer reference_registration.dispose();
    const symbol_registration = try features.document_symbol_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .display_name = "fake",
        .provide_document_symbols = Fake.symbols,
    });
    defer symbol_registration.dispose();

    const tab = workbench.activeTab().?;
    try tab.editor.setCursorPosition(Position.init(3, 1));
    try std.testing.expect(try workbench.revealDefinition());
    try std.testing.expectEqual(@as(usize, 2), tab.editor.modelCursorPosition().lineNumber);

    try std.testing.expect(try workbench.gotoSymbolInEditor());
    try std.testing.expect(workbench.quick_access.isOpen());
    const picker = workbench.quick_access.inputService().pickerRef();
    try std.testing.expectEqual(@as(usize, 1), picker.items.items.len);
    picker.accept();
    try std.testing.expectEqual(@as(usize, 2), tab.editor.modelCursorPosition().lineNumber);

    try tab.editor.setCursorPosition(Position.init(3, 1));
    try std.testing.expect(try workbench.goToReferences());
    try std.testing.expect(workbench.quick_access.isOpen());
    const reference_picker = workbench.quick_access.inputService().pickerRef();
    try std.testing.expectEqual(@as(usize, 3), reference_picker.items.items.len);
    reference_picker.accept();
    try std.testing.expectEqual(@as(usize, 1), tab.editor.modelCursorPosition().lineNumber);

    try tab.editor.setCursorPosition(Position.init(3, 1));
    try workbench.commands.execute("references-view.findReferences");
    reference_picker.accept();
    try workbench.commands.execute("references-view.pickFromHistory");
    try std.testing.expectEqualStrings("value", picker.items.items[0].item.label);
    picker.accept();
    try std.testing.expectEqual(@as(usize, 3), reference_picker.items.items.len);
    reference_picker.accept();
    try std.testing.expectEqual(@as(usize, 1), workbench.reference_history.entries.items.len);
    try workbench.commands.execute("references-view.clearHistory");
    try std.testing.expectEqual(@as(usize, 0), workbench.reference_history.entries.items.len);

    try std.testing.expect(try workbench.showHover());
    try std.testing.expect(tab.controllers.?.hover.isVisible());
}

test "Workbench: LSP no-result message keeps the word" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "lsp/empty.ts", "value");
    defer allocator.free(path);

    const Fake = struct {
        fn empty(_: *anyopaque, _: Allocator, _: *@import("../vs/editor/common/model/textModel.zig").TextModel, _: Position, _: CancellationToken) ![]languages.LocationLink {
            return &.{};
        }
    };

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 10);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();
    const features = workbench.language_features.?;
    var context: u8 = 0;
    const registration = try features.definition_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_definition = Fake.empty,
    });
    defer registration.dispose();

    try std.testing.expect(!(try workbench.revealDefinition()));
    try std.testing.expect(std.mem.indexOf(u8, workbench.activeTab().?.editor.message(), "No definition found for 'value'") != null);
}

test "Workbench: F12 and Shift+F12 dispatch through keybindings" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "lsp/keys.ts",
        \\\alpha
        \\\beta
    );
    defer allocator.free(path);

    const Fake = struct {
        fn definition(_: *anyopaque, allocator_: Allocator, model: *@import("../vs/editor/common/model/textModel.zig").TextModel, _: Position, _: CancellationToken) ![]languages.LocationLink {
            const uri = try std_uri.resourceKey(allocator_, model.uri());
            const links = try allocator_.alloc(languages.LocationLink, 1);
            links[0] = .{ .uri = uri, .range = Range.init(2, 1, 2, 5), .target_selection_range = Range.init(2, 1, 2, 5) };
            return links;
        }
        fn references(_: *anyopaque, allocator_: Allocator, model: *@import("../vs/editor/common/model/textModel.zig").TextModel, _: Position, _: languages.ReferenceContext, _: CancellationToken) ![]languages.Location {
            const uri = try std_uri.resourceKey(allocator_, model.uri());
            const locations = try allocator_.alloc(languages.Location, 2);
            locations[0] = .{ .uri = try allocator_.dupe(u8, uri), .range = Range.init(1, 1, 1, 5) };
            locations[1] = .{ .uri = try allocator_.dupe(u8, uri), .range = Range.init(2, 1, 2, 5) };
            allocator_.free(uri);
            return locations;
        }
    };

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 10);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();
    const features = workbench.language_features.?;
    var context: u8 = 0;
    const definition_registration = try features.definition_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_definition = Fake.definition,
    });
    defer definition_registration.dispose();
    const reference_registration = try features.reference_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_references = Fake.references,
    });
    defer reference_registration.dispose();

    const tab = workbench.activeTab().?;
    var f12 = ui.KeyEvent{ .key = .f12 };
    try std.testing.expect(try workbench.handleGlobalKey(&f12));
    try std.testing.expectEqual(@as(usize, 2), tab.editor.modelCursorPosition().lineNumber);

    try tab.editor.setCursorPosition(Position.init(1, 1));
    var shift_f12 = ui.KeyEvent{ .key = .f12, .mods = .{ .shift = true } };
    try std.testing.expect(try workbench.handleGlobalKey(&shift_f12));
    try std.testing.expect(workbench.quick_access.isOpen());
    workbench.quick_access.inputService().hide();
}

test "Workbench: same-file navigation reuses the current editor across path forms" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "lsp/relative.ts",
        \\\const value = 1;
        \\\value;
    );
    defer allocator.free(path);
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try Io.Dir.cwd().realPathFile(io, path, &absolute_buffer);
    const absolute = try allocator.dupe(u8, absolute_buffer[0..absolute_length]);
    defer allocator.free(absolute);
    const directory = std.fs.path.dirname(absolute) orelse "/";
    const basename = std.fs.path.basename(absolute);

    const Fake = struct {
        dir: []const u8,
        base: []const u8,
        fn definition(context: *anyopaque, allocator_: Allocator, _: *@import("../vs/editor/common/model/textModel.zig").TextModel, _: Position, _: CancellationToken) ![]languages.LocationLink {
            const self: *@This() = @ptrCast(@alignCast(context));
            const uri = try std.fmt.allocPrint(allocator_, "file:///{s}/./{s}", .{ self.dir, self.base });
            const links = try allocator_.alloc(languages.LocationLink, 1);
            links[0] = .{
                .uri = uri,
                .range = Range.init(2, 1, 2, 6),
                .target_selection_range = Range.init(2, 1, 2, 6),
            };
            return links;
        }
    };
    var context = Fake{ .dir = directory, .base = basename };

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();
    try workbench.enableLanguageFeatures();
    const registration = try workbench.language_features.?.definition_provider.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_definition = Fake.definition,
    });
    defer registration.dispose();

    try std.testing.expect(try workbench.revealDefinition());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings(path, workbench.activeTab().?.editor.path);
    try std.testing.expectEqual(@as(usize, 2), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
}

test "Workbench: new terminal creates one tab and hover does not act" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 20);
    defer workbench.deinit();
    const service = try TerminalService.init(allocator, io, .{ .launch = launchTestTerminal });
    workbench.terminal_service = service;

    workbench.newTerminal() catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    // Toggling the panel with a terminal present must not create another.
    try workbench.showTerminal();
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    const panel = workbench.panelRect();
    const view = &workbench.terminal_tabbed_view;
    const layout = view.layoutForService(panel, service);
    try std.testing.expect(layout.sash_x == null);
    const expected_cols: u16 = @intCast(ui.cell.snap(layout.terminal.w));
    const expected_rows: u16 = @intCast(ui.cell.snap(layout.terminal.h));
    const first = service.at(0).?;
    try std.testing.expectEqual(expected_cols, first.cols);
    try std.testing.expectEqual(expected_rows, first.rows);

    const title_y = ui.cell.snap(panel.y);
    var plus_x = ui.cell.snap(panel.x);
    while (view.hitTest(service, panel, panel_part_mod.titleContentEnd(&workbench.panel_part, panel), plus_x, title_y) != .new_terminal) : (plus_x += 1) {
        if (plus_x >= ui.cell.snap(panel.right())) return error.TestUnexpectedResult;
    }
    var move = ui.MouseEvent{ .kind = .move, .x = plus_x, .y = title_y };
    try std.testing.expect(workbench.handleTerminalMouse(&move));
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    var right = ui.MouseEvent{ .kind = .down, .button = .right, .x = plus_x, .y = title_y };
    try std.testing.expect(workbench.handleTerminalMouse(&right));
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    var click = ui.MouseEvent{ .kind = .down, .button = .left, .x = plus_x, .y = title_y };
    try std.testing.expect(workbench.handleTerminalMouse(&click));
    try std.testing.expectEqual(@as(usize, 2), workbench.terminalCount());
    // Both terminals resize when the second instance reveals the side list.
    const with_tabs = view.layoutForService(panel, service);
    try std.testing.expect(with_tabs.sash_x != null);
    try std.testing.expectEqual(with_tabs.terminal.x + with_tabs.terminal.w + 1, with_tabs.tabs.x);
    const resized_cols: u16 = @intCast(ui.cell.snap(with_tabs.terminal.w));
    try std.testing.expectEqual(resized_cols, first.cols);
    const second = service.at(1).?;
    try std.testing.expectEqual(resized_cols, second.cols);
    try std.testing.expectEqual(expected_rows, second.rows);

    // The tab strip switches on a left press only.
    try std.testing.expectEqual(@as(usize, 1), service.group.active);
    var tab_move = ui.MouseEvent{ .kind = .move, .x = ui.cell.snap(with_tabs.tabs.x) + 1, .y = ui.cell.snap(with_tabs.tabs.y) };
    try std.testing.expect(workbench.handleTerminalMouse(&tab_move));
    try std.testing.expectEqual(@as(usize, 1), service.group.active);
    var tab_right = ui.MouseEvent{ .kind = .down, .button = .right, .x = ui.cell.snap(with_tabs.tabs.x) + 1, .y = ui.cell.snap(with_tabs.tabs.y) };
    try std.testing.expect(workbench.handleTerminalMouse(&tab_right));
    try std.testing.expectEqual(@as(usize, 1), service.group.active);
    var escape: ui.KeyEvent = .{ .key = .escape };
    try std.testing.expect(workbench.handleContextMenuKey(&escape));
    var tab_click = ui.MouseEvent{ .kind = .down, .button = .left, .x = ui.cell.snap(with_tabs.tabs.x) + 1, .y = ui.cell.snap(with_tabs.tabs.y) };
    try std.testing.expect(workbench.handleTerminalMouse(&tab_click));
    try std.testing.expectEqual(@as(usize, 0), service.group.active);
}

test "Workbench: wheel scrolls the terminal viewport without moving focus" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 20);
    defer workbench.deinit();
    const service = try TerminalService.init(allocator, io, .{ .launch = launchTestTerminal });
    workbench.terminal_service = service;
    workbench.newTerminal() catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };

    const instance = service.at(0).?;
    const content = workbench.terminal_tabbed_view.layoutForService(workbench.panelRect(), service).terminal;
    const local_rect = ui.Rect{ .x = 0, .y = 0, .w = content.w, .h = content.h };

    var line_buffer: [64]u8 = undefined;
    var index: usize = 0;
    while (index < 60) : (index += 1) {
        const line = try std.fmt.bufPrint(&line_buffer, "line-{d}\r\n", .{index});
        instance.emulator.feed(line);
    }

    var grid = try ui.CellGrid.init(allocator, ui.cell.snap(content.w), ui.cell.snap(content.h));
    defer grid.deinit();
    try terminal_view.paint(&instance.emulator, &grid, local_rect);
    const active_top = try grid.rowText(allocator, 0);
    defer allocator.free(active_top);

    // Wheel-up over the content scrolls into the scrollback but must not steal
    // keyboard focus from the editor.
    workbench.focus = .editor;
    var wheel_up = ui.MouseEvent{
        .kind = .wheel,
        .x = ui.cell.snap(content.x) + 1,
        .y = ui.cell.snap(content.y) + 1,
        .delta_y = -3,
    };
    try std.testing.expect(workbench.handleTerminalMouse(&wheel_up));
    try std.testing.expect(workbench.focus == .editor);
    try terminal_view.paint(&instance.emulator, &grid, local_rect);
    const scrolled_top = try grid.rowText(allocator, 0);
    defer allocator.free(scrolled_top);
    try std.testing.expect(!std.mem.eql(u8, active_top, scrolled_top));

    // Wheel-down returns to the active viewport.
    var wheel_down = ui.MouseEvent{
        .kind = .wheel,
        .x = ui.cell.snap(content.x) + 1,
        .y = ui.cell.snap(content.y) + 1,
        .delta_y = 3,
    };
    try std.testing.expect(workbench.handleTerminalMouse(&wheel_down));
    try terminal_view.paint(&instance.emulator, &grid, local_rect);
    const returned_top = try grid.rowText(allocator, 0);
    defer allocator.free(returned_top);
    try std.testing.expectEqualStrings(active_top, returned_top);

    // A click focuses the terminal; the wheel alone does not.
    var click = ui.MouseEvent{
        .kind = .down,
        .button = .left,
        .x = ui.cell.snap(content.x) + 1,
        .y = ui.cell.snap(content.y) + 1,
    };
    try std.testing.expect(workbench.handleTerminalMouse(&click));
    try std.testing.expect(workbench.focus == .terminal);
}

test "Workbench: image files open in an image preview tab without touching the file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 12);
    defer workbench.deinit();
    const tab = workbench.activeTab().?;
    try std.testing.expect(tab.isImage());
    try std.testing.expect(tab.image_input != null);
    try std.testing.expect(tab.file_input == null);
    try std.testing.expect(tab.editor.read_only);
    try std.testing.expectEqualStrings("logo.png", tab.input.getName());

    // No kitty support: the pane renders the message instead of alt/binary text.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const message_text = try paneTextAlloc(allocator, tab.image_preview.?);
    defer allocator.free(message_text);
    try std.testing.expect(std.mem.indexOf(u8, message_text, "kitty graphics") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "kitty graphics") != null);

    // Ctrl-S is a no-op for image tabs.
    try workbench.commands.execute("workbench.action.files.save");
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &test_png_1x1, bytes);
}

test "Workbench: a capable terminal uploads and paints the image" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 12);
    defer workbench.deinit();
    workbench.setImageProtocol(.unicode_placeholders);
    workbench.setCellPixelSize(8, 16);
    const tab = workbench.activeTab().?;
    try std.testing.expect(tab.isImage());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b_Ga=t,f=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\u{10EEEE}") != null);
    var saw_placeholder = false;
    const surface = &tab.image_preview.?.surface.?;
    var row: usize = 0;
    while (row < surface.grid().rows) : (row += 1) {
        var col: usize = 0;
        while (col < surface.grid().cols) : (col += 1) {
            if (surface.grid().cluster[surface.grid().index(col, row)] == ui.image.placeholder_codepoint) saw_placeholder = true;
        }
    }
    try std.testing.expect(saw_placeholder);

    // The zoom command updates the viewer and the status entries.
    try workbench.commands.execute("imagePreview.zoomIn");
    workbench.refreshStatus();
    try std.testing.expect(workbench.media_status.?.last.scale != null);
    const scale = tagScale(workbench.media_status.?.last.scale.?);
    try std.testing.expect(scale > 1);

    // Zoomed clicks change the pane's scale too.
    var click = ui.MouseEvent{ .kind = .down, .button = .left, .x = 2, .y = 2 };
    try std.testing.expectEqual(
        @import("imagePreview.zig").Action.changed,
        tab.handleImageMouse(&click, false),
    );
}

test "Workbench: image files reload on change and open in a text editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 12);
    defer workbench.deinit();
    workbench.setImageProtocol(.unicode_placeholders);
    const tab = workbench.activeTab().?;
    const pane = tab.image_preview.?;
    const before = pane.editor.load_id;

    workbench.handleFileChanges(&.{.{ .type = .UPDATED, .resource = path }});
    try std.testing.expect(pane.editor.load_id > before);
    try std.testing.expect(workbench.pollFileWatcher(time_compat.milliTimestamp()));

    try workbench.openActiveImageAsText();
    const text_tab = workbench.activeTab().?;
    try std.testing.expect(!text_tab.isImage());
    try std.testing.expectEqualStrings("logo.png", text_tab.input.getName());
}

test "Workbench: session serialization restores image tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 12);
    defer workbench.deinit();

    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    var file_serializer = FileEditorSerializer.init(allocator, io, 40, 10);
    _ = try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, file_serializer.interface());
    var image_serializer = ImagePreviewEditorInputSerializer.init(allocator);
    _ = try registry.registerEditorSerializer(ImagePreviewEditorInput.ID, image_serializer.interface());

    var serialized = try workbench.serializePart(allocator, &registry);
    defer serialized.deinit(allocator);

    const restored = try Workbench.initFromSerializedPart(allocator, io, serialized, &registry, 40, 12);
    defer restored.deinit();
    const restored_tab = restored.activeTab().?;
    try std.testing.expect(restored_tab.isImage());
    try std.testing.expectEqualStrings("logo.png", restored_tab.input.getName());
}

test "Workbench: markdown preview shows displayable images" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try seedBinary(allocator, io, &tmp, "shot.png", &test_png_1x1);
    defer allocator.free(image_path);
    const markdown_path = try seedFile(allocator, io, &tmp, "with-image.md", "# Title\n\n![shot](shot.png)\n");
    defer allocator.free(markdown_path);

    const workbench = try Workbench.init(allocator, io, &.{markdown_path}, 70, 18);
    defer workbench.deinit();
    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    try workbench.toggleMarkdownPreview(pane);
    try std.testing.expect(tab.markdown_preview != null);

    // Without placeholder support the alt text is preserved and no image is
    // loaded into the document.
    var plain: std.Io.Writer.Allocating = .init(allocator);
    defer plain.deinit();
    try workbench.render(&plain.writer);
    try std.testing.expectEqual(@as(usize, 0), tab.markdown_preview.?.document.?.images.len);
    var saw_alt = false;
    const preview_surface = &tab.markdown_preview.?.surface.?;
    var alt_row: usize = 0;
    while (alt_row < preview_surface.grid().rows) : (alt_row += 1) {
        const text = try preview_surface.grid().rowText(allocator, alt_row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "shot") != null) saw_alt = true;
    }
    try std.testing.expect(saw_alt);

    workbench.setImageProtocol(.unicode_placeholders);
    workbench.setCellPixelSize(8, 16);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    // The workbench loads preview images on its background I/O pool.
    for (0..2000) |_| {
        _ = workbench.markdownPreviewTick(time_compat.milliTimestamp());
        try workbench.render(&out.writer);
        if (std.mem.indexOf(u8, out.written(), "\u{10EEEE}") != null) break;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\u{10EEEE}") != null);

    const preview = tab.markdown_preview.?;
    try std.testing.expect(preview.document != null);
    try std.testing.expectEqual(@as(usize, 1), preview.document.?.images.len);
}

test "Workbench: closing an image tab releases the terminal image" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 40, 12);
    defer workbench.deinit();
    workbench.setImageProtocol(.unicode_placeholders);
    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try workbench.render(&first.writer);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "a=t,f=100") != null);

    try workbench.commands.execute("workbench.action.closeActiveEditor");
    try std.testing.expect(workbench.images.hasPending());
    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();
    try workbench.render(&second.writer);
    try std.testing.expect(std.mem.indexOf(u8, second.written(), "a=d,d=I") != null);
}

test "Workbench: interactive open reads on the async Io" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "async-open.txt", "async body");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 10);
    defer workbench.deinit();

    workbench.requestOpenPath(path);
    try std.testing.expect(workbench.pending_open != null);
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    var waited: usize = 0;
    while (!workbench.pollAsyncReads() and waited < 2000) : (waited += 1) {
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    const tab = workbench.activeTab().?;
    var content = try tab.editor.model.getLineContent(1);
    defer content.deinit();
    try std.testing.expectEqualStrings("async body", content.items);
}

test "Workbench: cancelling an in-flight open leaves no tab and no pending job" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "cancel-open.txt", "body");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{}, 40, 10);
    workbench.requestOpenPath(path);
    workbench.deinit();
}

test "Workbench: Explorer expands a directory symlink and opens a file inside" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const ExplorerItem = @import("../vs/workbench/contrib/files/common/explorerModel.zig").ExplorerItem;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "real");
    var inner = try tmp.dir.createFile(io, "real/inner.txt", .{});
    try inner.writeStreamingAll(io, "inside link");
    inner.close(io);
    try tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const inner_path = try std.fmt.allocPrint(allocator, "{s}/link/inner.txt", .{root});
    defer allocator.free(inner_path);

    const workbench = try Workbench.init(allocator, io, &.{}, 70, 14);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    workbench.focusSidebar();

    const sidebar = workbench.sidebar.?;
    const link = sidebar.model.roots.items[0].getChild("link").?;
    try std.testing.expect(link.is_directory);
    try std.testing.expect(link.is_symbolic_link);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const rect = sidebar.last_rect;
    const left = ui.cell.snap(rect.x);
    const top = ui.cell.snap(rect.y) + sidebar.header_rows;

    const RowPosition = struct {
        fn find(sidebar_: *Sidebar, item: *ExplorerItem) ?usize {
            var index: usize = 0;
            while (index < sidebar_.count()) : (index += 1) {
                if (sidebar_.renderedItem(index) == item) return index;
            }
            return null;
        }
    };

    // A single click on the twistie expands the linked directory; before the
    // type was resolved the row was a file and the click tried to open it.
    const link_click = ui.MouseEvent{
        .kind = .down,
        .x = left + 2,
        .y = top + (RowPosition.find(sidebar, link) orelse return error.TestUnexpectedResult),
        .button = .left,
    };
    try std.testing.expect(workbench.handleSidebarMouse(&link_click));
    try std.testing.expect(sidebar.hasPendingLoad());
    var load_waited: usize = 0;
    while (!sidebar.pollLoad() and load_waited < 2000) : (load_waited += 1) {
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(load_waited < 2000);
    try std.testing.expect(sidebar.isExpanded(link));
    const inner_item = link.getChild("inner.txt") orelse return error.TestUnexpectedResult;

    // A single click on the child opens it through the link path and reads the
    // target, so files inside a linked directory have their real content.
    try workbench.render(&out.writer);
    const inner_click = ui.MouseEvent{
        .kind = .down,
        .x = left + 2,
        .y = top + (RowPosition.find(sidebar, inner_item) orelse return error.TestUnexpectedResult),
        .button = .left,
    };
    try std.testing.expect(workbench.handleSidebarMouse(&inner_click));
    pumpOpenForTests(workbench);
    const tab = workbench.activeTab() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(inner_path, tab.editor.path);
    var content = try tab.editor.model.getLineContent(1);
    defer content.deinit();
    try std.testing.expectEqualStrings("inside link", content.items);
}

test "Workbench: explorer sticky headers pin the folder ancestors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "aaa/bbb/ccc");
    var file_a = try tmp.dir.createFile(io, "aaa/a.txt", .{});
    try file_a.writeStreamingAll(io, "a");
    file_a.close(io);
    var file_b = try tmp.dir.createFile(io, "aaa/bbb/b.txt", .{});
    try file_b.writeStreamingAll(io, "b");
    file_b.close(io);
    for (0..12) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "aaa/bbb/ccc/f{d:0>2}.txt", .{i});
        var file = try tmp.dir.createFile(io, name, .{});
        try file.writeStreamingAll(io, "x");
        file.close(io);
    }

    const seed = try seedFile(allocator, io, &tmp, "sticky_seed.txt", "seed");
    defer allocator.free(seed);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{seed}, 60, 14);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    workbench.focusSidebar();

    var first_frame: std.Io.Writer.Allocating = .init(allocator);
    defer first_frame.deinit();
    try workbench.render(&first_frame.writer);

    const sidebar = workbench.sidebar.?;
    const deep = try std.fmt.allocPrint(allocator, "{s}/aaa/bbb/ccc/f11.txt", .{root});
    defer allocator.free(deep);
    try sidebar.revealPath(deep);
    pumpSidebarForTests(workbench);

    var frame: std.Io.Writer.Allocating = .init(allocator);
    defer frame.deinit();
    try workbench.render(&frame.writer);

    try std.testing.expectEqual(@as(usize, 3), sidebar.tree.stickyScrollNodes().len);
    const explorer_body = workbench.explorer_container.?.bodyRect("explorer").?;
    const sticky_top = ui.cell.snap(explorer_body.y);
    const sticky_a = try workbench.frame.present().rowText(allocator, sticky_top);
    defer allocator.free(sticky_a);
    const sticky_b = try workbench.frame.present().rowText(allocator, sticky_top + 1);
    defer allocator.free(sticky_b);
    const sticky_c = try workbench.frame.present().rowText(allocator, sticky_top + 2);
    defer allocator.free(sticky_c);
    try std.testing.expect(std.mem.indexOf(u8, sticky_a, "aaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, sticky_b, "bbb") != null);
    try std.testing.expect(std.mem.indexOf(u8, sticky_c, "ccc") != null);

    // Tab moves the focus into the sticky widget; Escape leaves the widget
    // before the side bar returns focus to the editor.
    var tab = ui.KeyEvent{ .key = .tab };
    try std.testing.expect(try workbench.handleSidebarKey(&tab));
    try std.testing.expect(sidebar.tree.stickyScrollFocused());
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(try workbench.handleSidebarKey(&escape));
    try std.testing.expect(!sidebar.tree.stickyScrollFocused());
    try std.testing.expectEqual(Focus.sidebar, workbench.focus);

    // A second Escape leaves the side bar for the editor, as before.
    try std.testing.expect(try workbench.handleSidebarKey(&escape));
    try std.testing.expectEqual(Focus.editor, workbench.focus);
}

test "Workbench: right click on a tab neither closes nor activates it" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "right_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "right_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 40, 9);
    defer workbench.deinit();
    try workbench.activateIndex(1);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    const tab_x = pane.hits.items[0].start + 1;
    const tab_y = ui.cell.snap(pane.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = tab_x, .y = tab_y, .button = .right };
    try std.testing.expect(workbench.handleTabMouse(&down));
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expect(workbench.context_menu != null);
    var release = down;
    release.kind = .up;
    try std.testing.expect(workbench.handleContextMenuMouse(&release));
    try std.testing.expect(workbench.context_menu != null);
    try std.testing.expectEqual(tab_x, workbench.context_menu.?.popup.?.options.x.?);
    try std.testing.expectEqual(tab_y, workbench.context_menu.?.popup.?.options.y.?);
    var escape = ui.KeyEvent{ .key = .escape };
    _ = workbench.handleContextMenuKey(&escape);

    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqualStrings("right_b.txt", workbench.activeTab().?.input.getName());
}

test "Workbench: inactive breadcrumbs reuse a persistent control" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "crumb_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "crumb_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 10);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expectEqual(@as(usize, 1), workbench.breadcrumbs_inactive.count());
    const first = workbench.breadcrumbs_inactive.get(workbench.part.group_views.items[0].group.id).?;

    try workbench.render(&out.writer);
    try std.testing.expectEqual(@as(usize, 1), workbench.breadcrumbs_inactive.count());
    try std.testing.expectEqual(first, workbench.breadcrumbs_inactive.get(workbench.part.group_views.items[0].group.id).?);
}

test "Workbench: content widgets show diagnostics in a rounded hover" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "hover-diagnostic.txt", "one\ntwo\nthree");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench = try Workbench.init(allocator, io, &.{path}, 100, 16);
    defer workbench.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.enableLanguageFeatures();
    const service = workbench.marker_service orelse return error.TestUnexpectedResult;
    const tab = workbench.activeTab() orelse return error.TestExpectedTab;

    var resource = markers_mod.Resource.fromUri(allocator, tab.editor.model.uri()) catch return error.TestUnexpectedResult;
    defer resource.deinit(allocator);
    try service.changeOne("test", resource, &.{
        .{
            .severity = markers_mod.MarkerSeverity.Error,
            .message = "boom",
            .source = "test",
            .start_line_number = 2,
            .start_column = 1,
            .end_line_number = 2,
            .end_column = 4,
        },
    }, null);

    try tab.editor.setCursorPosition(Position.init(2, 2));
    try std.testing.expect(try workbench.showHover());
    const controllers = tab.controllers orelse return error.TestUnexpectedResult;
    try std.testing.expect(controllers.hover.isVisible());
    const content = controllers.hover.widget().getWidgetContent() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, content, "Error: boom") != null);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    const rendered = try frameText(allocator, &workbench.frame);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "boom") != null);
    const fallback = &workbench.frame.prev;
    for ([_]u32{ '╭', '╮', '╰', '╯' }) |corner| {
        try std.testing.expect(std.mem.indexOfScalar(u32, fallback.cluster, corner) != null);
    }

    workbench.setCellBorderCapabilities(ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,outside,radius\x1b\\").?);
    try workbench.render(&out.writer);
    const native = &workbench.frame.prev;
    var joints: u8 = 0;
    for (0..native.rows) |y| {
        for (0..native.cols) |x| joints |= native.borderSetAt(x, y).joints;
    }
    const corner = ui.cell_border.Joint;
    try std.testing.expectEqual(corner.top_left | corner.top_right | corner.bottom_left | corner.bottom_right, joints);
    const native_text = try frameText(allocator, &workbench.frame);
    defer allocator.free(native_text);
    try std.testing.expect(std.mem.indexOf(u8, native_text, "boom") != null);
}

test "Workbench: tab overflow lists clipped tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "overflow_a.txt", "a");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "overflow_b.txt", "b");
    defer allocator.free(path_b);
    const path_c = try seedFile(allocator, io, &tmp, "overflow_c.txt", "c");
    defer allocator.free(path_c);
    const path_d = try seedFile(allocator, io, &tmp, "overflow_d.txt", "d");
    defer allocator.free(path_d);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b, path_c, path_d }, 28, 10);
    defer workbench.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    try std.testing.expect(pane.hits.items.len > 0);
    try std.testing.expect(pane.hits.items.len < pane.tabs.items.len);
    const first_hit = pane.hits.items[0].start;
    try std.testing.expect(first_hit > 0);

    var down = ui.MouseEvent{
        .kind = .down,
        .x = ui.cell.snap(pane.rect.x),
        .y = ui.cell.snap(pane.rect.y),
        .button = .left,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expect(workbench.context_menu != null);
    try std.testing.expect(workbench.handleContextMenuKey(&.{ .key = .home }));
    const hidden_name = try allocator.dupe(u8, workbench.context_menu.?.popup.?.focusedItem().?.label);
    defer allocator.free(hidden_name);

    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.handleContextMenuKey(&enter);
    try std.testing.expectEqualStrings(hidden_name, workbench.activeTab().?.input.getName());
}

test "Workbench: tab context menu closes to the right" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "right_a.txt", "a");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "right_b.txt", "b");
    defer allocator.free(path_b);
    const path_c = try seedFile(allocator, io, &tmp, "right_c.txt", "c");
    defer allocator.free(path_c);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b, path_c }, 60, 12);
    defer workbench.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    try std.testing.expect(workbench.handleContextMenuKey(&.{ .key = .home }));
    for (0..2) |_| try std.testing.expect(workbench.handleContextMenuKey(&.{ .key = .down }));
    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.handleContextMenuKey(&enter);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
}

test "Workbench: tab context menu splits the captured tab" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "split_a.txt", "a");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "split_b.txt", "b");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    defer workbench.deinit();
    try workbench.activateIndex(1);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    try std.testing.expect(workbench.handleContextMenuKey(&.{ .key = .home }));
    for (0..6) |_| try std.testing.expect(workbench.handleContextMenuKey(&.{ .key = .down }));
    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.handleContextMenuKey(&enter);

    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqualStrings("split_a.txt", workbench.activeTab().?.input.getName());
}

test "Workbench: tab context menu closes saved tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "saved_a.txt", "a");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "saved_b.txt", "b");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    defer workbench.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    try std.testing.expect(workbench.handleContextMenuKey(&.{ .key = .home }));
    for (0..3) |_| try std.testing.expect(workbench.handleContextMenuKey(&.{ .key = .down }));
    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.handleContextMenuKey(&enter);
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());
}

test "Workbench: close saved keeps dirty tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "dirty_saved_a.txt", "a");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "dirty_saved_b.txt", "b");
    defer allocator.free(path_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    defer workbench.deinit();
    try workbench.activateIndex(0);
    try workbench.activeTab().?.editor.insertText("x");
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(workbench.handleTabMouse(&down));
    try std.testing.expect(workbench.handleContextMenuKey(&.{ .key = .home }));
    for (0..3) |_| try std.testing.expect(workbench.handleContextMenuKey(&.{ .key = .down }));
    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.handleContextMenuKey(&enter);

    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("dirty_saved_a.txt", workbench.activeTab().?.input.getName());
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());
}

test "Workbench: hiding the tab row reclaims it for content" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "hidden_tabs.txt", "alpha");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 50, 10);
    defer workbench.deinit();
    const pane = workbench.part.group_views.items[0];
    pane.setBreadcrumbsVisible(false);
    pane.setTabsVisible(false);
    pane.layout();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const row = try workbench.frame.prev.rowText(allocator, ui.cell.snap(pane.rect.y));
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "hidden_tabs.txt") == null);
}

test "Workbench: the find bar reserves a view-zone row" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "find_zone.txt", "alpha\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19");
    defer allocator.free(path);

    const workbench = try Workbench.init(allocator, io, &.{path}, 60, 12);
    defer workbench.deinit();
    const tab = workbench.activeTab().?;
    try tab.ensureControllers();
    tab.controllers.?.find.widget().open();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);

    const pane = workbench.part.group_views.items[0];
    const top = ui.cell.snap(pane.rect.y) + pane.chromeHeight();
    const row = try workbench.frame.prev.rowText(allocator, top + 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "alpha") != null);
    try std.testing.expectEqual(@as(usize, 1), tab.top_view_zone_rows);

    _ = tab.editor.scrollViewLines(3);
    tab.view.invalidate();
    try workbench.render(&out.writer);
    try std.testing.expectEqual(@as(usize, 0), tab.top_view_zone_rows);
}

test "startup opens files at the laid-out pane width with one wrapping pass" {
    const allocator = std.testing.allocator;
    const wb = try Workbench.init(allocator, time_compat.io, &.{}, 140, 44);
    defer wb.deinit();
    try wb.initSidebarFromWorkspace();
    try wb.openPath("src/vs/workbench/browser/workbench.zig");
    const editor = wb.activeTab().?.editor;
    const pane = wb.activePane().?;
    try std.testing.expectEqual(pane.panes.page_position.?.width, editor.screen_width);
    try std.testing.expect(editor.screen_width < wb.cols);
    try std.testing.expectEqual(@as(usize, 1), editor.view_lines.rebuildAllCount());
}
