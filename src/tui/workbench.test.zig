// Terminal workbench integration tests, driven through the host and service APIs.
const TestWindow = @import("../vs/workbench/test/browser/workbenchTestServices.zig").TestWindow(@import("workbench.zig").TerminalWorkbench, @import("./editorView.zig").View.createHandle);
const terminal_workbench = @import("workbench.zig");
const renderFrame = terminal_workbench.renderFrame;
const cursorCell = @import("workbench.zig").cursorCell;
const shell = @import("workbenchWindow.zig");
const Focus = shell.Focus;
const GroupPane = shell.GroupPane;
const TabKeyResult = shell.TabKeyResult;
const Workbench = shell.TerminalWorkbench;
const DropZone = @import("../vs/workbench/browser/parts/editor/editorDropTarget.zig").Zone;
const color_utils = @import("../vs/platform/theme/common/colorUtils.zig");
const theme_colors_mod = @import("../vs/workbench/browser/themeColors.zig");
const terminal_ids = @import("../vs/workbench/contrib/terminal/common/terminal.zig").TerminalCommandId;
const scm_view_mod = @import("../vs/workbench/contrib/scm/browser/scmViewPane.zig");
const scm_history_view_mod = @import("../vs/workbench/contrib/scm/browser/scmHistoryViewPane.zig");
const scm_common = @import("../vs/workbench/contrib/scm/common/scm.zig");
const editor_part = @import("../vs/workbench/browser/parts/editor/editorPart.zig");
const sidebar_part_mod = @import("../vs/workbench/browser/parts/sidebar/sidebarPart.zig");
const sash_css = @import("../vs/base/browser/ui/sash/sash_css.zig");
const search_command_ids = @import("../vs/workbench/contrib/search/common/constants.zig").SearchCommandIds;
const layout_service_mod = @import("../vs/workbench/services/layout/browser/layoutService.zig");
const workbench_layout = @import("../vs/workbench/browser/layout.zig");
const WorkbenchGrid = workbench_layout.WorkbenchGrid;
const outline_pane_mod = @import("../vs/workbench/contrib/outline/browser/outlinePane.zig");
const OutlinePane = outline_pane_mod.OutlinePane;
const tui_editor_mod = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
const Editor = tui_editor_mod.Editor;
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
const file_icon = @import("../vs/workbench/services/themes/browser/fileIconThemeData.zig");
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

// The lifetime test compares an editor pointer against currently owned tabs
// without dereferencing a closed editor; production listeners use disposal.
fn ownsEditor(workbench: *const Workbench, editor: *const Editor) bool {
    for (workbench.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| if (tab.editor == editor) return true;
    }
    return false;
}

fn clickStatusEntry(workbench: *Workbench, id: []const u8) !bool {
    const part = workbench.statusbar.main_part;
    const handle = part.model.findHandle(id) orelse return false;
    const y = ui.cell.snap(workbench.geometry().statusBarRect().y);
    const width = ui.cell.snap(workbench.geometry().statusBarRect().w);
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
                    return terminal_workbench.handleStatusbarMouse(workbench, &event);
                },
                .part => {},
            }
        }
    }
    return false;
}

fn closeQuickAccess(workbench: *Workbench) !void {
    var escape = ui.KeyEvent{ .key = .escape };
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &escape);
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

fn paneTextAlloc(allocator: Allocator, pane: *@import("../vs/workbench/contrib/mediaPreview/browser/imagePreviewPane.zig").ImagePreviewPane) ![]u8 {
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

fn pumpDiffForTests(workbench: *Workbench) !void {
    var guard: usize = 0;
    while (workbench.editor_opening.pending_diff != null and guard < 5000) : (guard += 1) {
        _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
        if (workbench.editor_opening.pending_diff != null) std.Io.sleep(workbench.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(workbench.editor_opening.pending_diff == null);
}

fn pumpOpenForTests(workbench: *Workbench) void {
    var guard: usize = 0;
    while (workbench.editor_opening.pending_open != null and guard < 1000) : (guard += 1) {
        _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
        if (workbench.editor_opening.pending_open != null) std.Io.sleep(workbench.async_io, .fromMilliseconds(1), .awake) catch {};
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
    const workbench_window = try TestWindow.init(allocator, io, &.{}, 90, 32);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try renderFrame(workbench, &out.writer);
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
    try std.testing.expect(terminal_workbench.handleWatermarkKey(workbench, &.{ .key = .tab }));
    try std.testing.expectEqual(commands_row, watermark.root.document.focusedElement().?);
    try std.testing.expect(terminal_workbench.handleWatermarkKey(workbench, &.{ .key = .down }));
    try std.testing.expectEqual(terminal_row, watermark.root.document.focusedElement().?);
    try std.testing.expect(terminal_workbench.handleWatermarkKey(workbench, &.{ .key = .up }));
    try std.testing.expectEqual(commands_row, watermark.root.document.focusedElement().?);
    try std.testing.expect(terminal_workbench.handleWatermarkKey(workbench, &.{ .key = .enter }));
    try std.testing.expect(workbench.quick_access.isOpen());
    var escape = ui.KeyEvent{ .key = .escape };
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &escape);

    const hit = search_row.first_child.?.prev.?.asElement().rect;
    var mouse = ui.MouseEvent{ .kind = .move, .x = ui.cell.snap(hit.x), .y = ui.cell.snap(hit.y) };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &mouse));
    try std.testing.expectEqual(ui.Pointer.pointer, workbench.pointer);
    mouse.kind = .down;
    mouse.button = .left;
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &mouse));
    try std.testing.expectEqualStrings("search", workbench.activity_bar_part.active_id.?);

    try workbench.openPath(path);
    try renderFrame(workbench, &out.writer);
    try std.testing.expectEqual(ui.style.Display.none, watermark.root.declaredDisplay());
    try std.testing.expect(workbench.activeTab() != null);
    _ = try workbench.closeActive();
    try renderFrame(workbench, &out.writer);
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
    const workbench_window = try TestWindow.init(allocator, io, &.{}, 90, 32);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    try workbench.setKeybindingsPaths(&.{path});
    try workbench.resize(90, 12);
    try renderFrame(workbench, &out.writer);
    const short = try frameText(allocator, &workbench.frame);
    defer allocator.free(short);
    try std.testing.expect(std.mem.indexOf(u8, short, "Ctrl+Alt+G") != null);
    try std.testing.expect(std.mem.indexOf(u8, short, "Find in Files") != null);
    try std.testing.expect(std.mem.indexOf(u8, short, "Toggle Terminal") == null);
    try std.testing.expect(std.mem.indexOf(u8, short, "▗▄██▙▄▖") == null);

    workbench.ensureConfigurationReady();
    try workbench.setUserConfigurationValue(editor_group_watermark.settings_key, .{ .bool = false });
    try workbench.resize(90, 32);
    try renderFrame(workbench, &out.writer);
    const inactive = try frameText(allocator, &workbench.frame);
    defer allocator.free(inactive);
    try std.testing.expect(std.mem.indexOf(u8, inactive, "▗▄██▙▄▖") != null);
    try std.testing.expect(std.mem.indexOf(u8, inactive, "Show All Commands") == null);
    try std.testing.expect(!terminal_workbench.handleWatermarkKey(workbench, &.{ .key = .tab }));
}

test "Workbench: threaded tokenizer shuts down after tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "tokenized.zig", "const value = 1; // comment\n");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const tab = workbench.activeTab().?;
    try tab.ensureControllers();
    if (tab.controllers) |controllers| {
        _ = controllers.sticky.onTick(std.math.maxInt(i64));
    }
    _ = tab.editor.setTopViewLine(5);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
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

    const workbench_window = try TestWindow.init(allocator, time_compat.io, &.{buffer[0..length]}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
    try std.testing.expectEqualStrings("b.txt", workbench.activeTab().?.input.getName());

    try workbench.activeTab().?.ensureControllers();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "b.txt") != null);
    try std.testing.expectEqual(@as(usize, 2), cursorCell(workbench).?.row);

    try workbench.activateIndex(0);
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.getName());
    try workbench.switchTab(1);
    try std.testing.expectEqualStrings("b.txt", workbench.activeTab().?.input.getName());

    const ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try terminal_workbench.handleTabKey(workbench, &ctrl_w));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.getName());
    try std.testing.expectEqual(TabKeyResult.handled, try terminal_workbench.handleTabKey(workbench, &ctrl_w));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    const closed = workbench.activeTab().?.editor;
    const kept = workbench.part.group_views.items[0].tabs.items[0].editor;
    try std.testing.expect(ownsEditor(workbench, closed));
    try std.testing.expect(ownsEditor(workbench, kept));

    try workbench.activeTab().?.ensureControllers();
    const ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try terminal_workbench.handleTabKey(workbench, &ctrl_w));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    // `closed` is only compared, never dereferenced: the tab close freed it.
    try std.testing.expect(!ownsEditor(workbench, closed));
    try std.testing.expect(ownsEditor(workbench, kept));
}

test "Workbench: reopening an open file reuses its tab and editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "reuse.txt", "alpha");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

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

    const workbench_window = try TestWindow.init(allocator, io, &.{path_a}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    try workbench.openPath(path_b);
    const tab = workbench.activeTab().?;
    try std.testing.expectEqual(@as(usize, 0), @import("./editorView.zig").View.nativeView(tab.view).renderCount());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    try std.testing.expectEqual(@as(usize, 1), @import("./editorView.zig").View.nativeView(tab.view).renderCount());
}

test "Workbench: markdown preview toggle changes the current editor in place" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "preview.md", "# Title\n\nHello **world**\n");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    try std.testing.expect(tab.isMarkdown());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    const hit = pane.title_action_hit orelse return error.TestUnexpectedResult;
    const row = ui.cell.snap(pane.rect.y);
    const grid = &workbench.frame.prev;
    try std.testing.expectEqual(@as(u32, 0x25EB), grid.cluster[grid.index(hit.start, row)]);
    try std.testing.expectEqual(@as(u32, 0x2315), grid.cluster[grid.index(hit.start + 1, row)]);

    try workbench.markdown_previews.togglePreview(pane);
    try std.testing.expect(tab.markdown_preview != null);
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());

    var close_key = ui.KeyEvent{ .key = .{ .char = 'v' }, .mods = .{ .ctrl = true, .shift = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &close_key));
    try std.testing.expect(tab.markdown_preview == null);
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &close_key));
    try std.testing.expect(tab.markdown_preview != null);
    try renderFrame(workbench, &out.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const pane = workbench.activePane().?;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(pane.title_action_hit == null);
    try workbench.markdown_previews.togglePreview(pane);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 70, 18);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    try workbench.markdown_previews.openDynamicPreview(true);
    const preview_tab = workbench.activeTab().?;
    try std.testing.expect(preview_tab.markdown_preview != null);

    _ = tab.editor.setTopViewLine(30);
    const now = @import("../vs/base/common/timeCompat.zig").milliTimestamp();
    while (workbench.window_events.nextTimeout(now + 60, 1) == 0) _ = workbench.window_events.dispatch(now + 60);
    try std.testing.expect(preview_tab.markdown_preview.?.scroll > 0);
    while (workbench.window_events.nextTimeout(now + 120, 1) == 0) _ = workbench.window_events.dispatch(now + 120);

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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);

    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 3), workbench.tabCount());
    try std.testing.expectEqualStrings("split_b.txt", workbench.activeTab().?.input.getName());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 70, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const left = workbench.activePane().?;
    _ = try workbench.commands.execute("workbench.action.splitEditorRight");
    const right = workbench.activePane().?;
    try std.testing.expect(right != left);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    // Let sticky scroll complete its initial update before changing focus.
    const inactive = right.activeTab().?;
    _ = inactive.controllers.?.sticky.onTick(std.math.maxInt(i64));
    _ = try workbench.commands.execute("workbench.action.focusLeftGroup");
    try std.testing.expectEqual(left, workbench.activePane().?);
    try renderFrame(workbench, &out.writer);

    const active = workbench.activeTab().?;
    try std.testing.expect(!@import("./editorView.zig").View.nativeView(inactive.view).needsRender());
    try active.editor.deleteRight();
    // The input loop refreshes the active view before painting the workbench.
    try active.view.refresh();
    try renderFrame(workbench, &out.writer);

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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 70, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const left = workbench.activePane().?;
    try workbench.splitActive(.horizontal);
    const right = workbench.activePane().?;
    const left_tab = left.activeTab().?;
    const right_tab = right.activeTab().?;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(right_tab.view.isFocused());
    const surface = workbench.editor_surface;
    try std.testing.expectEqual(surface.document(), @import("./editorView.zig").View.nativeView(left_tab.view).root_node.?.document);
    try std.testing.expectEqual(surface.document(), @import("./editorView.zig").View.nativeView(right_tab.view).root_node.?.document);
    try std.testing.expectEqual(left.dom.?.editor_container, left_tab.element.?.parent.?);
    try std.testing.expectEqual(right.dom.?.editor_container, right_tab.element.?.parent.?);
    try std.testing.expect(left.dom.?.split_view.hasClass(editor_css.splitview.Class.split_view_view));
    try std.testing.expect(@import("./editorView.zig").View.nativeView(left_tab.view).root_node.?.hasClass(editor_css.code_editor.Class.monaco_editor));

    const x = ui.cell.snap(left.rect.x) + left_tab.editor.gutterWidth();
    const y = ui.cell.snap(left.rect.y) + left.chromeHeight();
    var wheel = ui.MouseEvent{ .kind = .wheel, .x = x, .y = y, .delta_y = 3 };
    try std.testing.expect(!terminal_workbench.handleTabMouse(workbench, &wheel));
    const target = terminal_workbench.editorMouseEvent(workbench, wheel) orelse return error.TestExpectedWheelTarget;
    try std.testing.expectEqual(left_tab, target.tab);
    const hit = (try surface.elementFromPoint(x, y)) orelse return error.TestExpectedWheelTarget;
    surface.document().dispatchMouse(hit, &wheel);
    try renderFrame(workbench, &out.writer);

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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const first = workbench.activePane().?;

    _ = try workbench.commands.execute("workbench.action.newGroupRight");
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    const second = workbench.activePane().?;
    try std.testing.expect(second != first);
    try std.testing.expect(second.activeTab() == null);

    const first_group = ui.KeyEvent{ .key = .{ .char = '1' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &first_group));
    try std.testing.expectEqual(first, workbench.activePane().?);
    const chord = ui.KeyEvent{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } };
    const right = ui.KeyEvent{ .key = .right, .mods = .{ .ctrl = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &chord));
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &right));
    try std.testing.expectEqual(second, workbench.activePane().?);

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
    try renderFrame(workbench, &out.writer);

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

test "Workbench: new editor group preserves sidebar focus" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "new_group_focus.txt", "alpha");
    defer allocator.free(path);
    const window = try TestWindow.init(allocator, io, &.{path}, 80, 20);
    defer window.deinit();
    const workbench = window.workbench;
    try workbench.setWorkspaceFolders(&.{std.fs.path.dirname(path).?});
    try workbench.showExplorer();
    try std.testing.expectEqual(Focus.sidebar, workbench.focus);
    const source = workbench.activePane().?;
    try workbench.commands.execute("workbench.action.newGroupRight");
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expect(workbench.activePane().? != source);
    try std.testing.expect(workbench.activePane().?.activeTab() == null);
    try std.testing.expectEqual(Focus.sidebar, workbench.focus);
}

test "Workbench: new group below and above focus commands" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "group_vertical.txt", "alpha");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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
    try renderFrame(workbench, &out.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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
        const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 12);
        const workbench = workbench_window.workbench;
        defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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
    try workbench.group_actions.joinAllGroups();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    workbench.setCellBorders(true);

    try std.testing.expectEqual(@as(usize, 25), ui.cell.snap(workbench.part.root.kind.split.first.rect.w));
    const boundary = ui.cell.snap(workbench.part.root.kind.split.first.rect.right());

    var down = ui.MouseEvent{ .kind = .down, .x = boundary, .y = 2, .button = .left };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &down));
    try std.testing.expect(workbench.part.active_sash != null);

    var move = ui.MouseEvent{ .kind = .move, .x = 30, .y = 2, .button = .left };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &move));
    try std.testing.expectEqual(@as(f64, 0.6), workbench.part.root.kind.split.ratio);
    try std.testing.expectEqual(@as(usize, 30), ui.cell.snap(workbench.part.root.kind.split.first.rect.w));

    var up = ui.MouseEvent{ .kind = .up, .x = 30, .y = 2, .button = .left };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &up));
    try std.testing.expect(workbench.part.active_sash == null);
}

test "Workbench: tabs and editor content resolve pointer shapes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "pointer_shape.txt", "abc");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    const tab_x = pane.hits.items[0].start;
    const title_y = ui.cell.snap(pane.rect.y);

    terminal_workbench.beginMousePointer(workbench);
    var over_tab = ui.MouseEvent{ .kind = .move, .x = tab_x, .y = title_y };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &over_tab));
    try std.testing.expectEqual(ui.Pointer.pointer, workbench.pointerShape());

    terminal_workbench.beginMousePointer(workbench);
    var empty_strip = over_tab;
    empty_strip.x = ui.cell.snap(pane.rect.right()) - 1;
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &empty_strip));
    try std.testing.expectEqual(ui.Pointer.default, workbench.pointerShape());

    terminal_workbench.beginMousePointer(workbench);
    const content = ui.MouseEvent{
        .kind = .move,
        .x = ui.cell.snap(pane.rect.x) + tab.editor.gutterWidth() + 1,
        .y = title_y + pane.chromeHeight(),
    };
    terminal_workbench.updateMousePointer(workbench, content);
    try std.testing.expectEqual(ui.Pointer.text, workbench.pointerShape());
}

test "Workbench: render emits OSC 22 only when the pointer changes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "pointer_render.txt", "abc");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 8);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    workbench.setPointerShapes(true);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // The initial default shape adds no bytes to the first frame.
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;") == null);

    out.clearRetainingCapacity();
    workbench.setPointer(.pointer);
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;pointer\x1b\\") != null);

    out.clearRetainingCapacity();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;") == null);

    out.clearRetainingCapacity();
    workbench.setPointer(.default);
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;default\x1b\\") != null);
}

test "Workbench: closing the last tab collapses the empty group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "collapse_a.txt", "alpha");
    defer allocator.free(path_a);

    const workbench_window = try TestWindow.init(allocator, io, &.{path_a}, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const source = workbench.part.group_views.items[1];
    const target = workbench.part.group_views.items[0];
    const tab_x = source.hits.items[0].start;
    const tab_y = ui.cell.snap(source.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = tab_x, .y = tab_y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &down));

    var move = ui.MouseEvent{
        .kind = .move,
        .x = ui.cell.snap(target.rect.x) + ui.cell.snap(target.rect.w) / 2,
        .y = ui.cell.snap(target.rect.y) + ui.cell.snap(target.rect.h) / 2,
        .button = .left,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &move));
    try std.testing.expect(workbench.editor_drop_target.editor_drag.active);

    var up = move;
    up.kind = .up;
    try std.testing.expect(terminal_workbench.handleTabDragMouse(workbench, &up));

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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    workbench.setCellBorders(true);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.part.group_views.items[0];
    const tab_y = ui.cell.snap(pane.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = pane.hits.items[0].start, .y = tab_y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &down));

    // Right half of the second tab: insert after it, not a top-edge split.
    const second = pane.hits.items[1];
    var move = ui.MouseEvent{
        .kind = .move,
        .x = second.start + (second.end - second.start) / 2 + 1,
        .y = tab_y,
        .button = .left,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &move));
    try std.testing.expect(workbench.editor_drop_target.editor_drag.active);
    try std.testing.expect(workbench.editor_drop_target.drag_target == null);
    try std.testing.expect(workbench.editor_drop_target.drag_tab_drop != null);
    try std.testing.expect(workbench.editor_drop_target.drag_tab_drop.?.pane == pane);
    try std.testing.expectEqual(@as(usize, 2), workbench.editor_drop_target.drag_tab_drop.?.index);

    // The strip paints upstream's drop-target-right line at the last tab edge.
    try renderFrame(workbench, &out.writer);
    const last = pane.hits.items[pane.hits.items.len - 1];
    const border = workbench.frame.prev.borderSetAt(last.end - 1, tab_y);
    try std.testing.expect(border.strokeAt(ui.cell_border.Segment.right) != null);

    var up = move;
    up.kind = .up;
    try std.testing.expect(terminal_workbench.handleTabDragMouse(workbench, &up));

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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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
    try renderFrame(workbench, &out.writer);

    const source_y = ui.cell.snap(source.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = source.hits.items[0].start, .y = source_y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &down));

    // The right half of the target's only tab inserts after it.
    const target_y = ui.cell.snap(target.rect.y);
    const target_hit = target.hits.items[0];
    var move = ui.MouseEvent{
        .kind = .move,
        .x = target_hit.end - 1,
        .y = target_y,
        .button = .left,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &move));
    try std.testing.expect(workbench.editor_drop_target.drag_tab_drop != null);
    try std.testing.expect(workbench.editor_drop_target.drag_tab_drop.?.pane == target);
    try std.testing.expectEqual(@as(usize, 1), workbench.editor_drop_target.drag_tab_drop.?.index);

    var up = move;
    up.kind = .up;
    try std.testing.expect(terminal_workbench.handleTabDragMouse(workbench, &up));

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
    const workbench_window = try TestWindow.init(allocator, io, &.{ a, b, c }, 120, 30);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

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
    try renderFrame(workbench, &out.writer);

    try sendDragMouse(workbench, 0, ui.cell.snap(group.rect.right()) - 2, ui.cell.snap(group.rect.y), false);
    try sendDragMouse(workbench, 32, original_left, center_y, false);
    try std.testing.expect(workbench.editor_drop_target.editor_drag.source.?.tab == null);
    try sendDragMouse(workbench, 0, original_left, center_y, true);
    try std.testing.expectEqual(id, workbench.activePane().?.group.id);
    try std.testing.expect(group.rect.x < original.rect.x);
    try renderFrame(workbench, &out.writer);

    const copy_mod: usize = if (builtin.os.tag == .macos) 8 else 16;
    try sendDragMouse(workbench, 0, ui.cell.snap(group.rect.right()) - 2, ui.cell.snap(group.rect.y), false);
    try sendDragMouse(workbench, 32 + copy_mod, far_right, center_y, false);
    try sendDragMouse(workbench, copy_mod, far_right, center_y, true);
    const copied = workbench.activePane().?;
    try std.testing.expect(copied.group.id != id and copied != original);
    try std.testing.expectEqual(@as(usize, 3), workbench.groupCount());
    try std.testing.expect(copied.activeTab().?.editor.model == group.activeTab().?.editor.model);
    try renderFrame(workbench, &out.writer);

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
    const workbench_window = try TestWindow.init(allocator, io, &.{ a, b }, 100, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    const pane = workbench.activePane().?;
    const y = ui.cell.snap(pane.rect.y);

    try sendDragMouse(workbench, 0, pane.hits.items[0].start, y, false);
    try sendDragMouse(workbench, 32, pane.hits.items[1].start, y, false);
    const hover = workbench.editor_drop_target.drag_hover orelse return error.MissingDragHover;
    const deadline = hover.deadline.?;
    // Drive the same scheduler the terminal uses; other contributions may
    // have already registered earlier deadlines on this window.
    for (0..256) |_| {
        if (workbench.window_events.nextTimeout(deadline - 1, 1) != 0) break;
        _ = workbench.window_events.dispatch(deadline - 1);
    }
    try std.testing.expect(workbench.activeTab() != hover.tab);
    try std.testing.expectEqual(deadline, workbench.editor_drop_target.drag_task.at.?);
    for (0..256) |_| {
        if (workbench.editor_drop_target.drag_task.at == null) break;
        _ = workbench.window_events.dispatch(deadline);
    }
    try std.testing.expect(workbench.activeTab() == hover.tab);
    try std.testing.expect(workbench.editor_drop_target.cancelEditorDrag());
    try std.testing.expect(workbench.editor_drop_target.drag_hover == null and workbench.editor_drop_target.drag_tab_drop == null);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 60, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 60, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);

    var serializer = workbench.createFileSerializer();
    defer serializer.deinit();
    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, serializer.interface());

    var data = try workbench.service.activeGroup().model.serialize(allocator, &registry);
    defer data.deinit(allocator);

    var groups = [_]@TypeOf(data){data};
    const restored_window = try TestWindow.initWithOptions(allocator, io, &.{}, 60, 9, .{}, .{ .data = .{ .groups = &groups, .active_group = 0 }, .registry = &registry });
    const restored = restored_window.workbench;
    defer restored_window.deinit();

    try std.testing.expectEqual(@as(usize, 2), restored.tabCount());
    try std.testing.expectEqualStrings("restore_b.txt", restored.activeTab().?.input.getName());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(restored, &out.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 70, 26);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.vertical);
    workbench.part.resizeSash(workbench.part.root, 20, 9);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    var serializer = workbench.createFileSerializer();
    defer serializer.deinit();
    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, serializer.interface());

    var data = try workbench.part.createState(allocator, &registry);
    defer data.deinit(allocator);

    const session = @import("../vs/workbench/browser/parts/editor/editorSession.zig");
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/groups.json", .{tmp.sub_path});
    defer allocator.free(path);
    try session.savePart(allocator, io, path, &data);
    var loaded = (try session.loadPart(allocator, io, path)).?;
    defer loaded.deinit(allocator);
    const restored_window = try TestWindow.initWithOptions(allocator, io, &.{}, 70, 26, .{}, .{ .data = loaded, .registry = &registry });
    const restored = restored_window.workbench;
    defer restored_window.deinit();

    try std.testing.expectEqual(@as(usize, 2), restored.groupCount());
    try std.testing.expectEqual(.vertical, restored.part.root.kind.split.direction);
    try std.testing.expectEqual(workbench.part.root.kind.split.first.rect.h, restored.part.root.kind.split.first.rect.h);
    // Group one restores A + B and group two restores the split copy of B.
    try std.testing.expectEqual(@as(usize, 3), restored.tabCount());
    try std.testing.expectEqualStrings("part_b.txt", restored.activeTab().?.input.getName());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(restored, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "part_a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "part_b.txt") != null);
}

test "Workbench: serialize and restore multiple editor inputs including a real file diff" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const DiffView = @import("../vs/workbench/browser/parts/editor/editorPane.zig").DiffView;
    const diff_input = @import("../vs/workbench/common/editor/diffEditorInput.zig");
    const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var original: std.ArrayList(u8) = .empty;
    defer original.deinit(allocator);
    var modified: std.ArrayList(u8) = .empty;
    defer modified.deinit(allocator);
    for (0..40) |index| {
        var line: [32]u8 = undefined;
        const content = try std.fmt.bufPrint(&line, "line {d}\n", .{index});
        try original.appendSlice(allocator, content);
        try modified.appendSlice(allocator, if (index == 18) "changed content\n" else content);
    }
    const path_a = try seedFile(allocator, io, &tmp, "diff_a.txt", original.items);
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "diff_b.txt", modified.items);
    defer allocator.free(path_b);
    const window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 120, 12);
    defer window.deinit();
    const wb = window.workbench;
    const pane = wb.activePane().?;
    const original_file = pane.tabs.items[0].file_input.?;
    const modified_file = pane.tabs.items[1].file_input.?;
    const dimensions = pane.contentDimensions();
    const diff = try DiffView.createWithSources(wb.view_factory, allocator, io, .{ .original_path = path_a, .modified_path = path_b, .original_label = "A", .modified_label = "B" }, original.items, modified.items, dimensions.width, dimensions.height, .{}, .{ .original = .{ .file = original_file }, .modified = .{ .file = modified_file } }, null);
    const tab = try Tab.initDiff(allocator, diff);
    _ = try wb.service.openEditor(tab.input, pane.group, .{ .open = .{ .pinned = true, .active = true } });
    try pane.addTab(tab);
    try wb.editor_opening.configureRestoredTab(tab);
    try pane.activateTab(tab);
    tab.layoutCells(dimensions.width, dimensions.height);
    const left = Selection.init(19, 6, 19, 2);
    const right = Selection.init(19, 2, 19, 5);
    try diff.widget.original_editor.setSelections(&.{left});
    try diff.widget.modified_editor.setSelections(&.{right});
    _ = diff.widget.modified_editor.setScrollTop(16);
    var before = try diff.widget.saveViewState(allocator);
    defer before.deinit(allocator);
    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    var file_serializer = wb.createFileSerializer();
    defer file_serializer.deinit();
    var diff_serializer = diff_input.DiffEditorSerializer.init(allocator, &registry);
    try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, file_serializer.interface());
    try registry.registerEditorSerializer(diff_input.ID, diff_serializer.interface());
    var data = try wb.part.createState(allocator, &registry);
    defer data.deinit(allocator);
    try std.testing.expectEqual(1, data.editor_view_states.len);
    const session = @import("../vs/workbench/browser/parts/editor/editorSession.zig");
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/diff-session.json", .{tmp.sub_path});
    defer allocator.free(path);
    try session.savePart(allocator, io, path, &data);
    var loaded = (try session.loadPart(allocator, io, path)).?;
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(1, loaded.editor_view_states.len);
    const restored_window = try TestWindow.initWithOptions(allocator, io, &.{}, 120, 12, .{}, .{ .data = loaded, .registry = &registry });
    defer restored_window.deinit();
    const restored = restored_window.workbench;
    try std.testing.expectEqual(3, restored.tabCount());
    const restored_diff = restored.activeTab().?.diff orelse return error.DiffNotRestored;
    try std.testing.expect(restored_diff.original_input == .file and restored_diff.modified_input == .file);
    const restored_pane = restored.activePane().?;
    try std.testing.expectEqual(restored_pane.tabs.items[0].editor.model, restored_diff.widget.originalModel());
    try std.testing.expectEqual(restored_pane.tabs.items[1].editor.model, restored_diff.widget.modifiedModel());
    try std.testing.expectEqualStrings(path_a, restored_diff.model.original_path);
    try std.testing.expectEqualStrings(path_b, restored_diff.model.modified_path);
    try std.testing.expect(!restored_diff.widget.original_editor.isReadOnly());
    try std.testing.expect(!restored_diff.widget.modified_editor.isReadOnly());
    const left_selections = try restored_diff.widget.original_editor.getSelections();
    defer allocator.free(left_selections);
    const right_selections = try restored_diff.widget.modified_editor.getSelections();
    defer allocator.free(right_selections);
    try std.testing.expectEqualSlices(Selection, &.{left}, left_selections);
    try std.testing.expectEqualSlices(Selection, &.{right}, right_selections);
    var after = try restored_diff.widget.saveViewState(allocator);
    defer after.deinit(allocator);
    try std.testing.expectEqual(before.modified.viewState.firstPosition, after.modified.viewState.firstPosition);
    try std.testing.expectEqual(before.modified.viewState.firstPositionDeltaTop, after.modified.viewState.firstPositionDeltaTop);
}

test "Workbench: sidebar renders and opens a file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "side_a.txt", "alpha");
    defer allocator.free(path_a);

    const workbench_window = try TestWindow.init(allocator, io, &.{path_a}, 70, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

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
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "EXPLORER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "side_open.txt") != null);

    const explorer_body = workbench.explorer_container.?.bodyRect("explorer").?;
    const click = ui.MouseEvent{ .kind = .down, .x = 4, .y = ui.cell.snap(explorer_body.y) + 1 };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &click));
    pumpOpenForTests(workbench);
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqualStrings("side_open.txt", workbench.activeTab().?.input.getName());
    try std.testing.expectEqual(Focus.editor, workbench.focus);

    const ctrl_b = ui.KeyEvent{ .key = .{ .char = 'b' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try terminal_workbench.handleSidebarKey(workbench, &ctrl_b));
    try std.testing.expect(!workbench.layout.isVisible(.sidebar));
    try std.testing.expect(try terminal_workbench.handleSidebarKey(workbench, &ctrl_b));
    try std.testing.expect(workbench.layout.isVisible(.sidebar));
}

test "Search palette actions open the named view after the activity bar changes" {
    const window = try TestWindow.init(std.testing.allocator, std.testing.io, &.{}, 80, 20);
    defer window.deinit();
    const workbench = window.workbench;
    const views_mod = @import("../vs/workbench/services/views/common/viewsService.zig");
    const SearchView = @import("../vs/workbench/contrib/search/browser/searchViewTerminal.zig").SearchView;
    const views = try workbench.instantiation.invokeFunction(struct {
        fn get(accessor: @import("../vs/platform/instantiation/common/instantiation.zig").ServicesAccessor) !views_mod.IViewsService {
            return (try accessor.get(views_mod.views_service_id)).*;
        }
    }.get, .{});
    try workbench.initSidebarFromWorkspace();
    try workbench.activity_bar_part.removeActivity("explorer");
    try std.testing.expectEqualStrings("search", workbench.activity_bar_part.activityAtVisibleIndex(0).?.id);
    try std.testing.expect(workbench.search_window.view != null);

    try std.testing.expect(try workbench.showActivityById("scm"));
    try std.testing.expect(views.getActiveViewWithId(SearchView) == null);
    try workbench.commands.execute("toggleSearchCaseSensitive");
    try std.testing.expect(!workbench.search_window.view.?.widget.match_case);
    try workbench.commands.execute("search.action.focusNextSearchResult");
    try std.testing.expectEqualStrings("search", workbench.activity_bar_part.active_id.?);
    try std.testing.expectEqual(workbench.search_window.view.?, views.getActiveViewWithId(SearchView).?);
    try workbench.commands.execute("toggleSearchCaseSensitive");
    try std.testing.expect(workbench.search_window.view.?.widget.match_case);
    try workbench.commands.execute("search.action.viewAsTree");
    try std.testing.expectEqual(.tree, workbench.search_window.view.?.controller.view_mode);
}

// Exercise the same deadlines and native worker wakeups as an idle window.
fn waitForSearch(workbench: *Workbench) !void {
    const Signal = @import("wakeSignal.zig").Signal;
    const clock = @import("../vs/base/common/timeCompat.zig");
    var signal = try Signal.init();
    defer signal.deinit();
    workbench.window_events.setWake(.{ .context = &signal, .signal = Signal.notify });
    defer workbench.window_events.setWake(null);
    const end = clock.milliTimestamp() + 5000;
    while (true) {
        const sidebar_busy = if (workbench.search_window.view) |view| view.isSearchPending() else false;
        const tab = workbench.activeTab();
        const editor_busy = if (tab != null and tab.?.search_editor_input != null) tab.?.search_editor_input.?.search_editor.isSearchPending() else false;
        if (!sidebar_busy and !editor_busy) return;
        const now = clock.milliTimestamp();
        if (now >= end) return error.SearchCompletionTimeout;
        const timeout = workbench.window_events.nextTimeout(now, @intCast(end - now));
        if (timeout > 0) {
            if (@import("builtin").os.tag == .windows) {
                const native = struct {
                    extern "kernel32" fn WaitForSingleObject(handle: std.os.windows.HANDLE, milliseconds: u32) callconv(.winapi) u32;
                };
                if (native.WaitForSingleObject(signal.handles, @intCast(timeout)) == 0xffffffff) return error.SearchWaitFailed;
            } else {
                var fds = [_]std.posix.pollfd{.{ .fd = signal.handles[0], .events = std.posix.POLL.IN, .revents = 0 }};
                if (try std.posix.poll(&fds, timeout) > 0) signal.drain();
            }
        }
        const ready_at = clock.milliTimestamp();
        if (ready_at >= end) return error.SearchCompletionTimeout;
        _ = workbench.window_events.dispatch(ready_at);
    }
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);

    try workbench.findInFiles();
    const view = workbench.search_window.view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    try waitForSearch(workbench);
    try std.testing.expectEqual(@as(usize, 2), view.model.result.count());
    try std.testing.expectEqualStrings("2", workbench.activity_service.getContainerBadgeDescription("search").?);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "SEARCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2 results in 1 file") != null);
    view.controller.clearResults(true);
    try std.testing.expect(workbench.activity_service.getContainerBadgeDescription("search") == null);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_window.view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    try waitForSearch(workbench);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{first}, 80, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_window.view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    try waitForSearch(workbench);
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

    // Navigating to the match leaves the current search intact.
    _ = workbench.window_events.dispatch(@import("../vs/base/common/timeCompat.zig").milliTimestamp() + 600);
    try std.testing.expect(!view.model.isSearching());
    try std.testing.expectEqual(@as(usize, 2), view.model.result.count());
}

test "Workbench: an inactive result model updates only its file and can regain matches" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try seedFile(allocator, io, &tmp, "one.txt", "alpha");
    defer allocator.free(a);
    const b = try seedFile(allocator, io, &tmp, "two.txt", "alpha");
    defer allocator.free(b);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const window = try TestWindow.init(allocator, io, &.{ a, b }, 80, 20);
    defer window.deinit();
    const w = window.workbench;
    try w.initSidebar(root);
    try w.findInFiles();
    const view = w.search_window.view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    try waitForSearch(w);
    try std.testing.expectEqual(2, view.matchCount());
    const files = try view.model.result.matches(allocator);
    defer allocator.free(files);
    const editor = w.findOpenInput(a).?.editor;
    const edited = if (files[0].model == editor.model) files[0] else files[1];
    const other = if (edited == files[0]) files[1] else files[0];
    const original_match = other.matches()[0];
    try std.testing.expect(edited.model == editor.model);
    if (w.activeTab().?.editor == editor) try w.switchTab(1);
    try std.testing.expect(w.activeTab().?.editor != editor);
    try editor.applyTextEdits(&.{.{ .range = .init(1, 1, 1, 6), .text = "beta" }}, &.{});
    const deadline = edited.scheduler.at orelse return error.MissingFileMatchUpdate;
    while (w.window_events.nextTimeout(deadline - 1, 1) == 0) _ = w.window_events.dispatch(deadline - 1);
    try std.testing.expectEqual(2, view.matchCount());
    while (w.window_events.nextTimeout(deadline, 1) == 0) _ = w.window_events.dispatch(deadline);
    try std.testing.expectEqual(1, view.matchCount());
    try editor.applyTextEdits(&.{.{ .range = .init(1, 1, 1, 5), .text = "alpha alpha" }}, &.{});
    const second_deadline = edited.scheduler.at.?;
    while (w.window_events.nextTimeout(second_deadline, 1) == 0) _ = w.window_events.dispatch(second_deadline);
    try std.testing.expectEqual(3, view.matchCount());
    try std.testing.expect(other.matches()[0] == original_match);
    try std.testing.expect(!view.model.isSearching());
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);

    try workbench.findInFiles();
    const view = workbench.search_window.view.?;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
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
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &down));
    try std.testing.expect(view.widget.replace_visible);
    try view.widget.setValue(.search, "alpha");
    try view.widget.setValue(.replace, "omega");
    view.model.setReplaceString("omega") catch {};
    try view.startSearch();
    try waitForSearch(workbench);
    try std.testing.expectEqual(@as(usize, 2), view.model.result.count());
    try renderFrame(workbench, &out.writer);
    const replace_all = view.widget.controlRect(.replace_all).?;
    const click = ui.MouseEvent{
        .kind = .down,
        .button = .left,
        .x = x + ui.cell.snap(replace_all.x),
        .y = y + ui.cell.snap(replace_all.y),
    };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &click));
    try std.testing.expect(view.replace_confirmation != null);
    try std.testing.expectEqual(@as(usize, 2), view.matchCount());
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &escape));
    try std.testing.expect(view.replace_confirmation == null);
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &click));
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &enter));

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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 70, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    workbench.focusSidebar();

    const search_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 2 };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &search_click));
    try std.testing.expectEqual(@as(usize, 1), workbench.activeActivity());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "SEARCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "No results") != null or std.mem.indexOf(u8, out.written(), "Search") != null);

    const scm_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 3 };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &scm_click));
    try std.testing.expectEqual(@as(usize, 2), workbench.activeActivity());
    out.clearRetainingCapacity();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Source Control") != null);

    // Upstream has no Settings view container: its activity bar gear is the
    // `workbench.actions.manage` global action that opens the Settings editor
    // as an editor tab, which is not ported. A click below the last entry
    // changes nothing.
    const empty_rail_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 4 };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &empty_rail_click));
    try std.testing.expectEqual(@as(usize, 2), workbench.activeActivity());
    try std.testing.expectEqual(@as(usize, 3), workbench.activity_bar_part.count());

    // The overflowing rail resolves its selection through the pane-composite
    // service, without invoking a native window menu-action dispatcher.
    try workbench.activity_bar_part.showOverflowMenu(.{ .x = 0, .y = 0, .w = 3, .h = 2 }, workbench.pane_composite_api, workbench.context_menu_api, .{ .x = 1, .y = 1 });
    try chooseContextMenuItem(workbench, "Search");
    try std.testing.expectEqualStrings("search", workbench.pane_composite_api.getActivePaneComposite(.sidebar).?.id);

    // Problems is a panel container: no activity-bar entry and no sidebar
    // container (upstream registers it in `ViewContainerLocation.Panel`).
    try std.testing.expect(!try workbench.showActivityById("problems"));
    try std.testing.expect(!workbench.geometry().panelShown());

    const alt_1 = ui.KeyEvent{ .key = .{ .char = '1' }, .mods = .{ .alt = true } };
    try std.testing.expect(try terminal_workbench.handleSidebarKey(workbench, &alt_1));
    try std.testing.expectEqual(@as(usize, 0), workbench.activeActivity());
}

test "Workbench: zen mode restores a status bar that was hidden before" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "zen_status.txt", "alpha\n");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 70, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.layout.setPartHidden(true, .statusbar);
    try std.testing.expect(!workbench.geometry().statusBarVisible());

    try workbench.toggleZenMode(false, false);
    try std.testing.expect(!workbench.geometry().statusBarVisible());
    try workbench.toggleZenMode(false, false);
    try std.testing.expect(!workbench.layout.isZenModeActive());
    try std.testing.expect(!workbench.geometry().statusBarVisible());
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    workbench.ensureConfigurationReady();

    const menu_id = @import("../vs/platform/actions/common/actions.zig").menu_ids.CommandPalette;
    const keys = try workbench.ensureContextKeys();
    const hide = workbench.commands.menus.getMenuItemPtr(menu_id, zen_mode_contribution.zen_hide_editor_tabs_id).?;
    const multiple = workbench.commands.menus.getMenuItemPtr(menu_id, zen_mode_contribution.zen_show_multiple_editor_tabs_id).?;
    const single = workbench.commands.menus.getMenuItemPtr(menu_id, zen_mode_contribution.zen_show_single_editor_tab_id).?;
    try std.testing.expect(!keys.contextMatchesRules(hide.command.precondition.?));
    try std.testing.expect(!keys.contextMatchesRules(multiple.command.precondition.?));
    try std.testing.expect(!keys.contextMatchesRules(single.command.precondition.?));

    try workbench.toggleZenMode(false, false);
    try std.testing.expect(keys.contextMatchesRules(hide.command.precondition.?));
    try std.testing.expect(!keys.contextMatchesRules(multiple.command.precondition.?));
    try std.testing.expect(keys.contextMatchesRules(single.command.precondition.?));

    try workbench.commands.execute(zen_mode_contribution.zen_hide_editor_tabs_id);
    try std.testing.expect(!keys.contextMatchesRules(hide.command.precondition.?));
    try std.testing.expect(keys.contextMatchesRules(multiple.command.precondition.?));
    try std.testing.expect(keys.contextMatchesRules(single.command.precondition.?));

    try workbench.commands.execute(zen_mode_contribution.zen_show_single_editor_tab_id);
    try std.testing.expect(keys.contextMatchesRules(hide.command.precondition.?));
    try std.testing.expect(keys.contextMatchesRules(multiple.command.precondition.?));
    try std.testing.expect(!keys.contextMatchesRules(single.command.precondition.?));
}

test "Workbench: zen mode keybindings toggle and exit" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    const ctrl_k = ui.KeyEvent{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &ctrl_k));
    const z = ui.KeyEvent{ .key = .{ .char = 'z' } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &z));
    try std.testing.expect(workbench.layout.isZenModeActive());

    const escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &escape));
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &escape));
    try std.testing.expect(!workbench.layout.isZenModeActive());
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 100, 16);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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
        .{ .severity = markers_mod.MarkerSeverity.Warning, .message = "second", .start_line_number = 3, .end_line_number = 3 },
    }, null);

    const status = workbench.statusbar.main_part.model.findEntry("status.problems") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, status.item.text(), "1") != null);

    try workbench.showProblems();
    try std.testing.expect(workbench.geometry().panelShown());
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.geometry().activePanelId());
    try std.testing.expectEqual(Focus.problems, workbench.focus);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "PROBLEMS") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "diag.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "boom") != null);
    try std.testing.expect(workbench.range_highlights.?.highlighted);

    const down = ui.KeyEvent{ .key = .down };
    try std.testing.expect(try terminal_workbench.handlePanelKey(workbench, &down));
    try std.testing.expectEqual(Focus.problems, workbench.focus);
    try std.testing.expectEqual(@as(usize, 3), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);
    try std.testing.expect(workbench.range_highlights.?.highlighted);
    try std.testing.expect(try terminal_workbench.handlePanelKey(workbench, &.{ .key = .up }));
    const enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try terminal_workbench.handlePanelKey(workbench, &enter));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 90, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.enableLanguageFeatures();
    try std.testing.expect(!workbench.geometry().panelShown());

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
    try std.testing.expect(!workbench.geometry().panelShown());
    try std.testing.expect(workbench.panel_part.pane.bar.findItemConst(PROBLEMS_CONTAINER_ID).?.visible);
    try workbench.showProblems();
    try std.testing.expect(workbench.geometry().panelShown());
    try std.testing.expect(workbench.panel_part.pane.bar.findItemConst(PROBLEMS_CONTAINER_ID).?.visible);

    // Toggling Problems while it owns focus hides the panel; toggling again
    // reveals the same container.
    try std.testing.expect(workbench.views_api.isViewVisible(markers_common.Markers.MARKERS_VIEW_ID));
    try workbench.toggleProblems();
    try std.testing.expect(!workbench.geometry().panelShown());
    try std.testing.expect(!workbench.views_api.isViewVisible(markers_common.Markers.MARKERS_VIEW_ID));
    try workbench.toggleProblems();
    try std.testing.expect(workbench.views_api.isViewVisible(markers_common.Markers.MARKERS_VIEW_ID));
    try std.testing.expect(workbench.geometry().panelShown());
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.geometry().activePanelId());

    // Ctrl-J closes and re-opens the panel with its last active container.
    const ctrl_j = ui.KeyEvent{ .key = .{ .char = 'j' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &ctrl_j));
    try std.testing.expect(!workbench.geometry().panelShown());
    try std.testing.expect(workbench.pane_composite_api.getActivePaneComposite(.panel) == null);
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.pane_composite_api.getLastActivePaneCompositeId(.panel).?);
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &ctrl_j));
    try std.testing.expect(workbench.geometry().panelShown());
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.pane_composite_api.getActivePaneComposite(.panel).?.id);

    // Ctrl-Shift-M toggles Problems through the registered keybinding.
    const ctrl_shift_m = ui.KeyEvent{ .key = .{ .char = 'm' }, .mods = .{ .ctrl = true, .shift = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &ctrl_shift_m));
    try std.testing.expect(!workbench.geometry().panelShown());
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &ctrl_shift_m));
    try std.testing.expect(workbench.geometry().panelShown());
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.geometry().activePanelId());

    // The Terminal container shares the panel title; upstream order puts
    // Problems (order 0) before Terminal (order 3).
    const terminal_service = try TerminalService.init(allocator, io, .{ .launch = launchTestTerminal });
    try workbench.attachTerminalService(terminal_service);
    workbench.newTerminal() catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqualStrings(TERMINAL_CONTAINER_ID, workbench.geometry().activePanelId());
    try std.testing.expect(workbench.terminalVisible());
    try workbench.commands.execute("workbench.action.previousPanelView");
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, workbench.geometry().activePanelId());
    try workbench.commands.execute("workbench.action.nextPanelView");
    try std.testing.expectEqualStrings(TERMINAL_CONTAINER_ID, workbench.geometry().activePanelId());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    const problems_index = std.mem.indexOf(u8, out.written(), "PROBLEMS") orelse return error.TestUnexpectedResult;
    const terminal_index = std.mem.indexOf(u8, out.written(), "TERMINAL") orelse return error.TestUnexpectedResult;
    try std.testing.expect(problems_index < terminal_index);

    // Clearing the markers drops the inactive Problems title again while the
    // panel and the Terminal tab stay.
    try service.changeOne("test", resource, &.{}, null);
    try std.testing.expect(!workbench.panel_part.pane.bar.findItemConst(PROBLEMS_CONTAINER_ID).?.visible);
    out.clearRetainingCapacity();
    try renderFrame(workbench, &out.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.initSidebarFromWorkspace();
    pumpSidebarForTests(workbench);
    workbench.focusSidebar();

    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());
    try std.testing.expect(workbench.activeTab() == null);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "EXPLORER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "folder_file.txt") != null);

    const explorer_body = workbench.explorer_container.?.bodyRect("explorer").?;
    const click = ui.MouseEvent{ .kind = .down, .x = 4, .y = ui.cell.snap(explorer_body.y) };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &click));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setWorkspaceFolders(&.{root});

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try terminal_workbench.handleQuickAccessKey(workbench, &ctrl_p));
    try std.testing.expect(workbench.isQuickAccessOpen());

    const picker = workbench.quick_access.controller.pickerRef();
    try picker.setValue("alp");
    var guard: usize = 0;
    while (picker.activeItem() == null and guard < 2000) : (guard += 1) {
        _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
        if (picker.activeItem() == null) time_compat.sleepMillis(1);
    }
    try std.testing.expectEqualStrings("alpha.txt", picker.activeItem().?.label);

    var enter = ui.KeyEvent{ .key = .enter };
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &enter);
    try std.testing.expect(!workbench.isQuickAccessOpen());
    var open_guard: usize = 0;
    while (workbench.tabCount() == 0 and open_guard < 2000) : (open_guard += 1) {
        _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expectEqualStrings("alpha.txt", workbench.activeTab().?.input.getName());
    try std.testing.expectEqual(@as(usize, 1), workbench.history.getHistory().len);

    // Alt-P opens the command palette directly; "split" runs the split command.
    var alt_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .alt = true } };
    try std.testing.expect(try terminal_workbench.handleQuickAccessKey(workbench, &alt_p));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try picker.setValue(">split");
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &enter);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.openPath(path_a);
    try workbench.openPath(path_b);
    try std.testing.expectEqualStrings("b.txt", workbench.sidebar.?.selectedNode().?.name);

    try workbench.switchTab(-1);
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.getName());
    try std.testing.expectEqualStrings("a.txt", workbench.sidebar.?.selectedNode().?.name);

    // Editor service events reveal resources even when another sidebar
    // composite is open; no native tab-switch or render hook is required.
    _ = try workbench.showActivityById("search");
    try workbench.editor_api.openEditor(path_b, .{});
    try std.testing.expectEqualStrings("b.txt", workbench.sidebar.?.selectedNode().?.name);
    _ = try workbench.showActivityById("explorer");
    try std.testing.expectEqualStrings("b.txt", workbench.sidebar.?.selectedNode().?.name);
}

test "Workbench: moveActiveEditor honors counts, center and selected tabs across groups" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try seedFile(allocator, io, &tmp, "move-a.txt", "a");
    defer allocator.free(a);
    const b = try seedFile(allocator, io, &tmp, "move-b.txt", "b");
    defer allocator.free(b);
    const c = try seedFile(allocator, io, &tmp, "move-c.txt", "c");
    defer allocator.free(c);
    const d = try seedFile(allocator, io, &tmp, "move-d.txt", "d");
    defer allocator.free(d);
    const window = try TestWindow.init(allocator, io, &.{ a, b, c, d }, 90, 24);
    defer window.deinit();
    const wb = window.workbench;
    try wb.activateIndex(0);
    const input = wb.activeTab().?.input;
    const source = wb.activePane().?;
    try wb.moveActiveEditor("right", "tab", 2);
    try std.testing.expectEqual(@as(usize, 2), source.group.model.indexOf(.{ .input = input }).?);
    try wb.moveActiveEditor("center", "tab", 1);
    try std.testing.expectEqual(@as(usize, 1), source.group.model.indexOf(.{ .input = input }).?);
    const other = source.group.model.getEditorByIndex(2).?;
    try source.group.model.setSelection(input, &.{other});
    try wb.moveActiveEditor("right", "group", 1);
    try std.testing.expectEqual(@as(usize, 2), wb.groupCount());
    try std.testing.expectEqual(@as(usize, 2), source.group.model.count());
    const target = wb.activePane().?;
    try std.testing.expect(target != source);
    try std.testing.expectEqual(@as(usize, 2), target.group.model.count());
    try std.testing.expect(target.group.model.activeEditor() == input);
    try std.testing.expect(target.group.model.indexOf(.{ .input = other }) != null);
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
    const workbench_window = try TestWindow.init(allocator, io, &.{}, 90, 24);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setKeybindingsPaths(&.{bindings});
    try workbench.openPath(file);
    const quick = workbench.quick_access;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try quick.showFilePicker();
    try renderFrame(workbench, &out.writer);
    const layout = quick.widget.layout;
    const right = layout.x + layout.width - layout.inset - 1;
    var click = ui.MouseEvent{ .kind = .down, .button = .left, .x = right - 5, .y = layout.y + layout.inset + 1 };
    try std.testing.expect(terminal_workbench.handleQuickAccessMouse(workbench, &click));
    try std.testing.expect(!quick.isOpen());
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqualStrings("CPU.hs", workbench.activeTab().?.input.getName());

    try quick.showFilePicker();
    try renderFrame(workbench, &out.writer);
    click.x = right - 2;
    try std.testing.expect(terminal_workbench.handleQuickAccessMouse(workbench, &click));
    try std.testing.expect(quick.isOpen());
    try std.testing.expectEqual(@as(usize, 0), workbench.history.getHistory().len);
    try std.testing.expectEqual(@as(usize, 0), quick.controller.pickerRef().rows.items.len);

    const command = "workbench.action.splitEditor";
    try quick.commands_provider.base.history.push(command);
    try quick.showCommandPicker();
    const picker = quick.controller.pickerRef();
    try picker.setValue(">" ++ command);
    try renderFrame(workbench, &out.writer);
    const keys = picker.activeItem().?.keycaps;
    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqualStrings("Ctrl", keys[0]);
    try std.testing.expectEqualStrings("Alt", keys[1]);
    try std.testing.expectEqualStrings("B", keys[2]);
    try std.testing.expect(terminal_workbench.handleQuickAccessMouse(workbench, &click));
    try std.testing.expect(quick.isOpen());
    try std.testing.expectEqual(@as(?usize, null), quick.commands_provider.base.history.rank(command));
    try renderFrame(workbench, &out.writer);
    var tab_key = ui.KeyEvent{ .key = .tab };
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try terminal_workbench.handleQuickAccessKey(workbench, &tab_key));
    try std.testing.expect(try terminal_workbench.handleQuickAccessKey(workbench, &enter));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 60, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setWorkspaceFolders(&.{root});

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try terminal_workbench.handleQuickAccessKey(workbench, &ctrl_p));

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Search files") != null);

    var click = ui.MouseEvent{ .kind = .down, .x = 0, .y = 9 };
    try std.testing.expect(terminal_workbench.handleQuickAccessMouse(workbench, &click));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.initSidebarFromWorkspace();
    pumpSidebarForTests(workbench);
    try workbench.setKeybindingsPaths(&.{keybindings_path});

    var j = ui.KeyEvent{ .key = .{ .char = 'j' } };
    // The binding is gated by `listFocus`; the editor does not match it.
    workbench.focusEditor();
    try std.testing.expect(!(try terminal_workbench.handleGlobalKey(workbench, &j)));
    workbench.focusSidebar();
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &j));

    // File-service notifications schedule the user-keybinding owner's reload
    // independently of settings.json, even while the editor is idle.
    const old = workbench.user_keybindings.current;
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = keybindings_path,
        .data = "[{ \"key\": \"k\", \"command\": \"list.focusDown\", \"when\": \"listFocus\" }]",
    });
    try workbench.file_watcher_service.?.on_did_change.fire(&.{.{ .type = .UPDATED, .resource = keybindings_path }});
    var guard: usize = 0;
    while (old == workbench.user_keybindings.current and guard < 1000) : (guard += 1) {
        _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(workbench.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(old != workbench.user_keybindings.current);
    try std.testing.expect(!(try terminal_workbench.handleGlobalKey(workbench, &j)));
    var k = ui.KeyEvent{ .key = .{ .char = 'k' } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &k));
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
        \\{ "workbench.colorTheme": "Test Theme", "workbench.iconTheme": null }
    );
    settings_file.close(io);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = try allocator.dupe(u8, buffer[0..root_len]);
    defer allocator.free(root);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{root});
    defer allocator.free(settings_path);

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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
    try std.testing.expect(service.getFileIconTheme().disabled);
    var changes: usize = 0;
    const listener = try service.onDidFileIconThemeChange.listen(&changes, struct {
        fn changed(data: file_icon.FileIconThemeData, count: *usize) !void {
            try std.testing.expect(!data.disabled);
            count.* += 1;
        }
    }.changed);
    defer service.onDidFileIconThemeChange.unlisten(listener);
    try workbench.setUserConfigurationValue("workbench.iconTheme", .{ .string = "vs-seti" });
    try std.testing.expect(!service.getFileIconTheme().disabled);
    try std.testing.expectEqual(@as(usize, 1), changes);
    try std.testing.expectEqualStrings("light", service.getFileIconTheme().variant);
    const palette = workbench.theme_palette.?;
    try std.testing.expectEqual(@as(u8, 0xff), palette.background.r);
    try std.testing.expectEqual(@as(u8, 0x10), palette.foreground.g);
    const status = palette.color("statusBar.background", .{ 0, 0, 0 });
    try std.testing.expectEqual(@as(u8, 0xee), status.r);

    // The service applies customizations through the configuration event
    // without an explicit host reload or a frame.
    var colors: std.json.ObjectMap = .empty;
    defer colors.deinit(allocator);
    try colors.put(allocator, "editor.background", .{ .string = "#123456" });
    try workbench.setUserConfigurationValue("workbench.colorCustomizations", .{ .object = colors });
    try std.testing.expectEqual(@as(u8, 0x12), workbench.theme_palette.?.background.r);
    try workbench.setUserConfigurationValue("workbench.colorCustomizations", null);
    try std.testing.expectEqual(@as(u8, 0xff), workbench.theme_palette.?.background.r);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const profile_settings = try seedFile(allocator, io, &tmp, "profile-settings.json", "{\"editor.tabSize\":2}");
    defer allocator.free(profile_settings);
    const profile_keybindings = try seedFile(allocator, io, &tmp, "profile-keybindings.json", "[]");
    defer allocator.free(profile_keybindings);
    try workbench.setUserSettingsPaths(&.{ profile_settings, settings_path });
    try workbench.setKeybindingsPaths(&.{ profile_keybindings, keybindings_path });

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
    const profile_contents = try workbench.text_file_service.read(profile_settings, allocator);
    defer allocator.free(profile_contents);
    try std.testing.expectEqualStrings("{\"editor.tabSize\":2}", profile_contents);
    // Opening the same editable resource must preserve existing contents.
    try workbench.commands.execute("workbench.action.openSettingsJson");
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    try std.testing.expectEqualStrings("settings.json", workbench.activeTab().?.input.getName());
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setKeybindingsPaths(&.{keybindings_path});
    workbench.focusEditor();

    const ctrl_alt_g = ui.KeyEvent{ .key = .{ .char = 'g' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &ctrl_alt_g));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try closeQuickAccess(workbench);

    // A user binding with the same chord as a default wins.
    var ctrl_b = ui.KeyEvent{ .key = .{ .char = 'b' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &ctrl_b));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try closeQuickAccess(workbench);

    // `when` clauses use the shared context keys.
    const ctrl_alt_n = ui.KeyEvent{ .key = .{ .char = 'n' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &ctrl_alt_n));
    try std.testing.expect(workbench.isQuickAccessOpen());
    try closeQuickAccess(workbench);
    const ctrl_alt_m = ui.KeyEvent{ .key = .{ .char = 'm' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(!(try terminal_workbench.handleGlobalKey(workbench, &ctrl_alt_m)));
    try std.testing.expect(!workbench.isQuickAccessOpen());

    // Unknown commands are filtered so they cannot swallow typing.
    const ctrl_alt_u = ui.KeyEvent{ .key = .{ .char = 'u' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(!(try terminal_workbench.handleGlobalKey(workbench, &ctrl_alt_u)));

    // Reloading applies removals: Ctrl+B no longer resolves globally.
    try writeKeybindingsFile(&tmp, io, keybindings_path, allocator,
        \\[
        \\  { "command": "-workbench.action.toggleSidebarVisibility" }
        \\]
    );
    try workbench.setKeybindingsPaths(&.{keybindings_path});
    try std.testing.expect(!(try terminal_workbench.handleGlobalKey(workbench, &ctrl_b)));
    try std.testing.expect(!(try terminal_workbench.handleGlobalKey(workbench, &ctrl_alt_g)));
}

test "Find reads language options before paint and observes settings changes immediately" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "file.json", "{}");
    defer allocator.free(path);
    const settings = try seedFile(allocator, io, &tmp, "settings.json",
        \\{
        \\    "[json]": { "editor.find.cursorMoveOnType": false, "editor.find.history": "never" },
        \\    "editor.find.seedSearchStringFromSelection": false,
        \\    "editor.find.autoFindInSelection": true
        \\}
    );
    defer allocator.free(settings);
    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setUserSettingsPaths(&.{settings});
    const find = workbench.activeTab().?.controllers.?.find;
    try std.testing.expect(!find.model.cursor_move_on_type);
    try std.testing.expect(!find.widget().history_enabled);
    try std.testing.expectEqual(.never, find.seed_search_string_from_selection);
    try std.testing.expectEqual(.always, find.auto_find_in_selection);

    try workbench.setUserConfigurationValue("editor.find.loop", .{ .bool = false });
    try std.testing.expect(!find.state.loop);
    try workbench.setUserConfigurationValue("editor.find.loop", null);
    try std.testing.expect(find.state.loop);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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
    try renderFrame(workbench, &rendered.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_window.view.?;

    try view.widget.setValue(.search, "zzz-not-found");
    try view.startSearch();
    try waitForSearch(workbench);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "No results found") != null);

    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    try waitForSearch(workbench);
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try renderFrame(workbench, &rendered.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{source}, 95, 25);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const sidebar = workbench.search_window.view.?;
    try sidebar.widget.setValue(.search, "alpha");
    try sidebar.startSearch();
    try waitForSearch(workbench);
    try sidebar.openInEditor();
    try waitForSearch(workbench);
    const tab = workbench.activeTab().?;
    const input = tab.search_editor_input.?;
    const query = input.search_editor;
    try std.testing.expectEqualStrings("alpha", query.form.value(.search));
    try std.testing.expectEqual(@as(usize, 1), query.form.contextLines());
    {
        const matches = try input.getMatchRanges(allocator);
        defer allocator.free(matches);
        try std.testing.expectEqual(@as(usize, 1), matches.len);
        var match_text = try tab.editor.model.getValueInRange(matches[0], null);
        defer match_text.deinit();
        try std.testing.expectEqualStrings("alpha", match_text.items);
    }

    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try renderFrame(workbench, &rendered.writer);
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
        try std.testing.expect(!terminal_workbench.handleSearchEditorMouse(workbench, &fold_click));
        var target = terminal_workbench.editorMouseEvent(workbench, fold_click).?;
        try std.testing.expect(try target.tab.view.dispatchMouse(&target.event));
        try std.testing.expectEqual(visible, tab.editor.isModelLineVisible(4));
        try renderFrame(workbench, &rendered.writer);
    }
    try std.testing.expect(workbench.activeTab() == tab);
    query.setQueryFocused(true);

    try query.form.setValue(.search, "beta");
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(terminal_workbench.handleSearchEditorKey(workbench, &enter));
    try waitForSearch(workbench);
    try std.testing.expect(workbench.activeTab() == tab);
    try std.testing.expectEqualStrings("Search: beta", input.base.getName());
    try std.testing.expectEqualStrings("alpha", sidebar.widget.value(.search));
    var second = try tab.editor.model.getValue(null, false);
    defer second.deinit();
    try std.testing.expect(std.mem.indexOf(u8, second.items, "  3  between\n  4: beta\n  5  after") != null);
    {
        const matches = try input.getMatchRanges(allocator);
        defer allocator.free(matches);
        try std.testing.expectEqual(@as(usize, 1), matches.len);
        var match_text = try tab.editor.model.getValueInRange(matches[0], null);
        defer match_text.deinit();
        try std.testing.expectEqualStrings("beta", match_text.items);
    }

    const toggle = query.form.controlRect(.toggle_context).?;
    try std.testing.expect(terminal_workbench.handleSearchEditorMouse(workbench, &.{
        .kind = .down,
        .button = .left,
        .x = ui.cell.snap(pane.rect.x + toggle.x),
        .y = ui.cell.snap(pane.rect.y + toggle.y) + pane.chromeHeight(),
    }));
    try waitForSearch(workbench);
    var no_context = try tab.editor.model.getValue(null, false);
    defer no_context.deinit();
    try std.testing.expect(std.mem.indexOf(u8, no_context.items, "  4: beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_context.items, "between") == null);

    query.form.setDetailsVisible(true);
    try renderFrame(workbench, &rendered.writer);
    query.form.focusField(.includes);
    try query.form.setValue(.includes, "*.zig");
    try std.testing.expect(terminal_workbench.handleSearchEditorKey(workbench, &enter));
    try waitForSearch(workbench);
    try renderFrame(workbench, &rendered.writer);
    tab.view.invalidate();
    try renderFrame(workbench, &rendered.writer);
    const results_y = ui.cell.snap(pane.rect.y) + pane.chromeHeight() + query.headerRows();
    const no_results_row = try workbench.frame.present().rowText(allocator, results_y);
    defer allocator.free(no_results_row);
    try std.testing.expect(std.mem.indexOf(u8, no_results_row, "No Results") != null);
    try query.form.setValue(.includes, "");
    try std.testing.expect(terminal_workbench.handleSearchEditorKey(workbench, &enter));
    try waitForSearch(workbench);

    query.setQueryFocused(false);
    try tab.editor.setCursorPosition(.{ .lineNumber = 4, .column = 6 });
    try std.testing.expect(terminal_workbench.handleSearchEditorKey(workbench, &enter));
    try std.testing.expect(workbench.activeTab() != tab);
    try std.testing.expectEqual(@as(usize, 4), workbench.activeTab().?.editor.modelCursorPosition().lineNumber);

    try workbench.switchTab(1);
    try std.testing.expect(workbench.activeTab() == tab);
    query.setQueryFocused(true);
    query.form.focusField(.search);
    try query.form.setValue(.search, "");
    try std.testing.expect(terminal_workbench.handleSearchEditorKey(workbench, &enter));
    try waitForSearch(workbench);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_window.view.?;

    for ([_][]const u8{ "t", "te", "tes", "test" }) |query| {
        try view.widget.setValue(.search, query);
        const deadline = view.controller.debounce_at orelse return error.MissingSearchDebounce;
        try std.testing.expectEqual(deadline, view.model.delivery.timer.at.?);
        _ = workbench.window_events.dispatch(deadline - 1);
        try std.testing.expect(!view.model.isSearching());
        try waitForSearch(workbench);
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
    try renderFrame(workbench, &out.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, paths.items, 80, 16);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_window.view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    try waitForSearch(workbench);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(view.rows.items.len > view.visible_rows);

    const selected_before = view.selected;
    const scroll_before = view.scroll;
    const x = ui.cell.snap(view.last_rect.x) + 2;
    const y = ui.cell.snap(view.last_rect.y) + view.results_y + 1;
    const wheel = ui.MouseEvent{ .kind = .wheel, .x = x, .y = y, .delta_y = 1 };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &wheel));
    try std.testing.expect(view.scroll > scroll_before);
    try std.testing.expectEqual(selected_before, view.selected);

    var after: std.Io.Writer.Allocating = .init(allocator);
    defer after.deinit();
    try renderFrame(workbench, &after.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 16);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_window.view.?;
    view.focusReplace();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(view.panel_focused);
    try std.testing.expectEqual(search_widget_mod.Field.replace, view.widget.focus_field);
    try std.testing.expect(!view.widget.search.focused);
    try std.testing.expect(view.widget.replace.focused);

    // Idle mode-1003 motion over the search row is hover only: the replace
    // field keeps the caret and panel focus does not change.
    const x = ui.cell.snap(view.last_rect.x) + 2;
    const y = ui.cell.snap(view.last_rect.y) + view.header_rows + view.widget.layout.search_y;
    var hover = ui.MouseEvent{ .kind = .move, .x = x, .y = y };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &hover));
    try std.testing.expect(view.panel_focused);
    try std.testing.expectEqual(search_widget_mod.Field.replace, view.widget.focus_field);
    out.clearRetainingCapacity();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(!view.widget.search.focused);
    try std.testing.expect(view.widget.replace.focused);

    // A press does move focus and the caret.
    var down = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &down));
    try std.testing.expectEqual(search_widget_mod.Field.search, view.widget.focus_field);
    out.clearRetainingCapacity();
    try renderFrame(workbench, &out.writer);
    try std.testing.expect(view.widget.search.focused);
    try std.testing.expect(!view.widget.replace.focused);

    // Leaving the side bar clears the visual focus as well as the controller
    // flag, so the caret does not keep looking focused behind the editor.
    workbench.focusEditor();
    out.clearRetainingCapacity();
    try renderFrame(workbench, &out.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    const model = &workbench.statusbar.main_part.model;
    const entry = if (model.findEntry("status.editor.mode")) |found| found else &model.entries()[0];
    const id = entry.id;
    try workbench.statusbar.main_part.showContextMenu(entry.handle, workbench.context_menu_api, .{ .x = 4, .y = 11, .opening_press = true }, .{ .layout_service = workbench.layout_api, .configuration_service = workbench.configuration_api });
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expect(workbench.context_menu_service.current != null);
    for (workbench.context_menu_service.current.?.popup.?.items) |item| {
        if (item.type == .checkbox) try std.testing.expect(item.label.len > 0);
    }
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .end }));
    try std.testing.expect(std.mem.startsWith(u8, workbench.context_menu_service.current.?.popup.?.focusedItem().?.label, "Hide"));

    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.context_menu_service.handleKey(&enter);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 80, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 120, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    try std.testing.expect(workbench.geometry().statusBarVisible());
    try std.testing.expectEqual(@as(usize, 9), ui.cell.snap(workbench.geometry().statusBarRect().y));

    const pane = workbench.part.group_views.items[0];
    try std.testing.expectEqual(@as(usize, 9), ui.cell.snap(pane.rect.h));
    try std.testing.expectEqual(@as(usize, 7), workbench.activeTab().?.editor.screen_height);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

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

    // Active editor subscriptions update the status before the next frame,
    // without a workbench status refresh.
    try workbench.activeTab().?.editor.setCursorPosition(Position.init(1, 3));
    workbench.activeTab().?.editor.setEncoding(.utf8_with_bom);
    try renderFrame(workbench, &out.writer);
    const updated_status = try workbench.frame.prev.rowText(allocator, 9);
    defer allocator.free(updated_status);
    try std.testing.expect(std.mem.indexOf(u8, updated_status, "Ln 1, Col 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated_status, "UTF-8 with BOM") != null);

    workbench.focusStatusBar();
    try std.testing.expectEqual(Focus.statusbar, workbench.focus);
    try std.testing.expect(workbench.statusbar.main_part.focusedHandle() != null);
    try std.testing.expect(cursorCell(workbench) == null);

    const right = ui.KeyEvent{ .key = .right };
    try std.testing.expect(try terminal_workbench.handleStatusbarKey(workbench, &right));
    const escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(try terminal_workbench.handleStatusbarKey(workbench, &escape));
    try std.testing.expect(workbench.statusbar.main_part.focusedHandle() == null);
    try std.testing.expect(try terminal_workbench.handleStatusbarKey(workbench, &escape));
    try std.testing.expectEqual(Focus.editor, workbench.focus);
}

test "Workbench: Ctrl-Alt-S toggles status bar focus" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "focus.txt", "x");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 8);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    const toggle = ui.KeyEvent{ .key = .{ .char = 's' }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(try terminal_workbench.handleStatusbarKey(workbench, &toggle));
    try std.testing.expectEqual(Focus.statusbar, workbench.focus);
    try std.testing.expect(try terminal_workbench.handleStatusbarKey(workbench, &toggle));
    try std.testing.expectEqual(Focus.editor, workbench.focus);
}

test "Workbench: clicking a status entry focuses it and runs its command" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "click.txt", "x");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 100, 8);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    const State = struct {
        hits: usize = 0,
        fn run(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.hits += 1;
        }
    };
    var state = State{};
    try workbench.commands.registerCommand(.{ .id = "test.statusbar.command", .context = &state, .run = State.run }, .{ .id = "test.statusbar.command", .title = "Status Command" }, .{});
    const accessor = try workbench.statusbar.addEntry(.{
        .name = "Status command",
        .text = "CMD",
        .command = .{ .id = "test.statusbar.command" },
    }, "test.statusbar.command", .right, .{ .number = 50 });
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const y = ui.cell.snap(workbench.geometry().statusBarRect().y);
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
    try std.testing.expect(terminal_workbench.handleStatusbarMouse(workbench, &click));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 120, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.indentation"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqualStrings("Indent Using Spaces", workbench.quick_access.inputService().pickerRef().activeItem().?.label);
    var escape = ui.KeyEvent{ .key = .escape };
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.encoding"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqualStrings("UTF-8", workbench.quick_access.inputService().pickerRef().activeItem().?.label);
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.eol"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqualStrings("LF", workbench.quick_access.inputService().pickerRef().activeItem().?.label);
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.mode"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &escape);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.selection"));
    try std.testing.expect(workbench.quick_access.isPickOpen());
    try std.testing.expectEqual(@as(usize, 0), workbench.quick_access.inputService().pickerRef().items.items.len);
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &escape);
    try std.testing.expect(!workbench.quick_access.isOpen());
}

test "Workbench: EOL and language pickers update the editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "pick-actions.txt", "alpha\nbeta\ngamma");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 120, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.encoding"));
    var down = ui.KeyEvent{ .key = .down };
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &down);
    var enter = ui.KeyEvent{ .key = .enter };
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &enter);
    try std.testing.expectEqual(
        encoding_mod.Encoding.utf8_with_bom,
        workbench.activeTab().?.editor.getEncoding(),
    );
    try std.testing.expectEqualStrings(
        "UTF-8 with BOM",
        workbench.statusbar.main_part.model.findEntry("status.editor.encoding").?.item.text(),
    );

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.eol"));
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &down);
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &enter);
    try std.testing.expect(!workbench.quick_access.isOpen());
    try std.testing.expectEqual(EOL.CRLF, workbench.activeTab().?.editor.model.getEOL());
    try std.testing.expectEqualStrings(
        "CRLF",
        workbench.statusbar.main_part.model.findEntry("status.editor.eol").?.item.text(),
    );

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.mode"));
    for ("zig") |ch| {
        var typed = ui.KeyEvent{ .key = .{ .char = ch } };
        _ = try terminal_workbench.handleQuickAccessKey(workbench, &typed);
    }
    try std.testing.expectEqualStrings("zig", workbench.quick_access.inputService().pickerRef().activeItem().?.id);
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &enter);
    try std.testing.expectEqualStrings("zig", workbench.activeTab().?.editor.languageId());
    try std.testing.expectEqualStrings(
        "Zig",
        workbench.statusbar.main_part.model.findEntry("status.editor.mode").?.item.text(),
    );

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.selection"));
    for ("2:3") |ch| {
        var typed = ui.KeyEvent{ .key = .{ .char = ch } };
        _ = try terminal_workbench.handleQuickAccessKey(workbench, &typed);
    }
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &enter);
    const selections = try workbench.activeTab().?.editor.getSelections();
    defer allocator.free(selections);
    try std.testing.expectEqual(@as(usize, 2), selections[0].startLineNumber);
    try std.testing.expectEqual(@as(usize, 3), selections[0].startColumn);

    try std.testing.expect(try clickStatusEntry(workbench, "status.editor.indentation"));
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &down);
    _ = try terminal_workbench.handleQuickAccessKey(workbench, &enter);
    try std.testing.expect(!workbench.activeTab().?.editor.model.getOptions().insertSpaces);
    try std.testing.expectEqualStrings(
        "Tab Size: 4",
        workbench.statusbar.main_part.model.findEntry("status.editor.indentation").?.item.text(),
    );
}

test "workbench: global shortcuts dispatch through the keybinding registry" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &ctrl_p));
    try std.testing.expect(workbench.isQuickAccessOpen());

    // While quick access owns the keyboard the global host steps aside.
    try std.testing.expect(!(try terminal_workbench.handleGlobalKey(workbench, &ctrl_p)));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.openPath(path);

    try std.testing.expectEqualStrings("zig", workbench.activeTab().?.editor.languageId());
    // Removing the key reclassifies the already-open editor immediately,
    // before a key press, frame or filesystem watcher notification.
    try workbench.setUserConfigurationValue("files.associations", null);
    try std.testing.expectEqualStrings("plaintext", workbench.activeTab().?.editor.languageId());
}

test "Workbench: starts a workspace file watcher for absolute folders" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try std.testing.expect(workbench.workspace_watcher == null);
    try workbench.lifecycle.setPhase(.Restored);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.lifecycle.setPhase(.Restored);

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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const tab = workbench.activeTab().?;

    try workbench.setWorkspaceFolders(&.{root});
    try workbench.lifecycle.setPhase(.Restored);
    const service = workbench.file_watcher_service.?;

    const ready_deadline = time_compat.milliTimestamp() + 3000;
    while (time_compat.milliTimestamp() < ready_deadline and !service.isReady()) {
        _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(service.isReady());

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "after" });

    const deadline = time_compat.milliTimestamp() + 3000;
    var reloaded = false;
    while (time_compat.milliTimestamp() < deadline and !reloaded) {
        _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

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
                if (terminal_workbench.handleTabDragMouse(workbench, mouse)) continue;
                if (terminal_workbench.handleQuickAccessMouse(workbench, mouse)) continue;
                if (terminal_workbench.handleStatusbarMouse(workbench, mouse)) continue;
                if (terminal_workbench.handleSashMouse(workbench, mouse)) continue;
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const first = workbench.part.root.kind.split.first;
    const boundary = ui.cell.snap(first.rect.right());

    var down = ui.MouseEvent{ .kind = .down, .x = boundary, .y = 2, .button = .left };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &down));
    try std.testing.expect(workbench.part.active_sash != null);

    // Mode 1003 terminals may report drag motion with button `none`; the
    // grabbed sash still follows the pointer instead of ending the drag.
    var move = ui.MouseEvent{ .kind = .move, .x = boundary + 6, .y = 2, .button = .none };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &move));
    try std.testing.expect(workbench.part.active_sash != null);
    try std.testing.expectEqual(@as(f64, 30.0 / 49.0), workbench.part.root.kind.split.ratio);

    var up = ui.MouseEvent{ .kind = .up, .x = boundary + 6, .y = 2, .button = .left };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &up));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.vertical);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

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
                if (terminal_workbench.handleTabDragMouse(workbench, mouse)) continue;
                if (terminal_workbench.handleQuickAccessMouse(workbench, mouse)) continue;
                if (terminal_workbench.handleStatusbarMouse(workbench, mouse)) continue;
                if (terminal_workbench.handleSashMouse(workbench, mouse)) continue;
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &down));
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expect(workbench.context_menu_service.current != null);
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .home }));
    try std.testing.expectEqualStrings("Close", workbench.context_menu_service.current.?.popup.?.focusedItem().?.label);

    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.context_menu_service.handleKey(&enter);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 60, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setWorkspaceFolders(&.{root});
    try workbench.openPath(path);
    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.activePane().?;
    try std.testing.expectEqual(@as(usize, 2), pane.chromeHeight());
    const row = try workbench.frame.prev.rowText(allocator, 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "src") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "http-proxy.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, ">") != null);
    try std.testing.expectEqual(@as(usize, 2), cursorCell(workbench).?.row);

    // The first breadcrumb item opens the folder picker.
    const control = workbench.breadcrumbs.activeControl().?;
    try std.testing.expect(control.widget.itemCount() >= 2);

    var needs_frame = false;
    var host = try @import("workbench.zig").TerminalHostLoop.init(workbench, &out.writer, null, null);
    defer host.deinit();
    host.scheduleFrames(&needs_frame);
    try control.model.?.refresh();
    try std.testing.expect(needs_frame);
    try host.render();

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
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &click));
    try std.testing.expect(!workbench.quick_access.inputService().isVisible());
    try std.testing.expect(workbench.breadcrumbs.pickerVisible());
    try std.testing.expect(workbench.breadcrumbs.picker.?.file != null);
    const picker = workbench.breadcrumbs.picker.?.file.?;
    try std.testing.expect(picker.selectedPath() != null);
    const rounded = ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,outside,radius\x1b\\").?;
    for ([_]?ui.cell_border.Capabilities{ null, rounded }) |caps| {
        workbench.setCellBorderCapabilities(caps);
        try renderFrame(workbench, &out.writer);
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
    try std.testing.expect(terminal_workbench.handleBreadcrumbPopupKey(workbench, &escape));
    try std.testing.expect(!workbench.breadcrumbs.pickerVisible());
    // Reopening creates a fresh data tree before reclaiming the old nodes.
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &click));
    try std.testing.expect(workbench.breadcrumbs.pickerVisible());
    try std.testing.expect(workbench.breadcrumbs.picker.?.file.?.selectedPath() != null);
    try std.testing.expect(terminal_workbench.handleBreadcrumbPopupKey(workbench, &escape));
    try workbench.commands.execute("breadcrumbs.focus");
    try std.testing.expectEqual(Focus.breadcrumbs, workbench.focus);
    try std.testing.expectEqual(control.widget.itemCount() - 1, control.widget.getFocused().?);
    try std.testing.expect(!workbench.breadcrumbs.pickerVisible());
    try workbench.commands.execute("breadcrumbs.focusAndSelect");
    try std.testing.expect(workbench.breadcrumbs.pickerVisible());
    try std.testing.expect(workbench.breadcrumbs.picker.?.file.?.selectedPath() != null);
    try std.testing.expect(terminal_workbench.handleBreadcrumbPopupKey(workbench, &escape));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 60, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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
    try renderFrame(workbench, &out.writer);

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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activeTab().?.ensureControllers();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.activePane().?;
    const hit = pane.hits.items[0];
    var click = ui.MouseEvent{
        .kind = .down,
        .x = hit.close_start.?,
        .y = ui.cell.snap(pane.rect.y),
        .button = .left,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &click));
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    // A dirty tab opens the save confirmation instead of closing.
    try workbench.openPath(path);
    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("x");
    try renderFrame(workbench, &out.writer);
    const pane2 = workbench.activePane().?;
    var click2 = ui.MouseEvent{
        .kind = .down,
        .x = pane2.hits.items[0].close_start.?,
        .y = ui.cell.snap(pane2.rect.y),
        .button = .left,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &click2));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(workbench.isDialogOpen());

    try renderFrame(workbench, &out.writer);
    const dialog_text = try frameText(allocator, &workbench.frame);
    defer allocator.free(dialog_text);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Do you want to save the changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "close.txt?") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Your changes will be lost") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Don't Save") != null);

    // Escape cancels the close and leaves the buffer dirty.
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &escape));
    try std.testing.expect(!workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());

    // Enter activates the focused primary button, saves, then closes.
    try renderFrame(workbench, &out.writer);
    const pane3 = workbench.activePane().?;
    var click3 = ui.MouseEvent{
        .kind = .down,
        .x = pane3.hits.items[0].close_start.?,
        .y = ui.cell.snap(pane3.rect.y),
        .button = .left,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &click3));
    try std.testing.expect(workbench.isDialogOpen());
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &enter));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("local ");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    const pane = workbench.activePane().?;
    var click = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].close_start.?,
        .y = ui.cell.snap(pane.rect.y),
        .button = .left,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &click));
    try std.testing.expect(workbench.isDialogOpen());

    var down = ui.KeyEvent{ .key = .down };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &down));
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &enter));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("x");

    var ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try terminal_workbench.handleTabKey(workbench, &ctrl_w));
    try std.testing.expect(workbench.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());

    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &escape));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activeTab().?.ensureControllers();

    // A clean workbench closes the window immediately.
    try std.testing.expect(workbench.requestQuit());
    try std.testing.expect(!workbench.isDialogOpen());

    try workbench.activeTab().?.editor.insertText("x");
    try std.testing.expect(!workbench.requestQuit());
    try std.testing.expect(workbench.isDialogOpen());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const dialog_text = try frameText(allocator, &workbench.frame);
    defer allocator.free(dialog_text);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Do you want to save the changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "quit_one.txt?") != null);

    // Cancel keeps the window and the dirty tab.
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &escape));
    try std.testing.expect(!workbench.shouldQuit());
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());

    // Save All saves the dirty tab, closes the window and lets the host exit.
    try std.testing.expect(!workbench.requestQuit());
    try std.testing.expect(workbench.isDialogOpen());
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &enter));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 60, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(0);
    try workbench.activeTab().?.editor.insertText("a");
    try workbench.activateIndex(1);
    try workbench.activeTab().?.editor.insertText("b");

    try std.testing.expect(!workbench.requestQuit());
    try std.testing.expect(workbench.isDialogOpen());
    // Upstream revealEditorsToConfirm opens the first dirty editor per group.
    try std.testing.expectEqualStrings("quit_a.txt", workbench.activeTab().?.input.getName());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const dialog_text = try frameText(allocator, &workbench.frame);
    defer allocator.free(dialog_text);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "following 2 files?") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "quit_a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "quit_b.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog_text, "Save All") != null);

    // Down moves focus to Don't Save; Enter discards both tabs and quits.
    var down = ui.KeyEvent{ .key = .down };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &down));
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &enter));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.openPreviewPath(path_a);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(!workbench.activePane().?.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));

    try workbench.openPreviewPath(path_b);
    try std.testing.expectEqual(@as(usize, 1), workbench.tabCount());
    try std.testing.expect(std.mem.endsWith(u8, workbench.activeTab().?.editor.path, "preview_b.txt"));

    try workbench.activeTab().?.ensureControllers();
    try workbench.activeTab().?.editor.insertText("x");
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.activeTab().?.ensureControllers();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.activePane().?;
    try std.testing.expectEqual(@as(usize, 1), pane.chromeHeight());
    try std.testing.expectEqual(@as(usize, 1), cursorCell(workbench).?.row);
}

test "Workbench: double click pins a preview tab and toggles a pinned group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "dblclick.txt", "alpha");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 40, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.openPreviewPath(path);
    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.activePane().?;
    const hit = pane.hits.items[0];
    const x = hit.start + 1;
    const y = ui.cell.snap(pane.rect.y);
    var first = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &first));
    try std.testing.expect(!pane.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));
    // A real terminal also delivers the release between the two presses.
    var up = ui.MouseEvent{ .kind = .up, .x = x, .y = y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &up));
    // Simulate a slow second click caused by the first activation's work.
    workbench.editor_drop_target.last_tab_click.?.at_ms -= 700;
    var second = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &second));
    try std.testing.expect(pane.group.model.isPinned(.{ .editor = workbench.activeTab().?.input }));
    try std.testing.expect(workbench.part.maximized_group == null);

    // The UI repaints the now-pinned label without italics.
    try renderFrame(workbench, &out.writer);
    const hit_after = pane.hits.items[0];
    var col = hit_after.start;
    while (col < hit_after.end) : (col += 1) {
        try std.testing.expect(grid_attr_italic(&workbench.frame.prev, col, y) == false);
    }

    // A second double click on the now-pinned tab expands the group.
    var third = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &third));
    var fourth = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &fourth));
    try std.testing.expect(workbench.part.maximized_group == pane);

    // And another double click restores the split layout.
    try renderFrame(workbench, &out.writer);
    var fifth = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &fifth));
    var sixth = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &sixth));
    try std.testing.expect(workbench.part.maximized_group == null);
}

test "Workbench: double click still pins after a jittery drag starts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "jitter.txt", "alpha");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 40, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.openPreviewPath(path);
    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.activePane().?;
    const hit = pane.hits.items[0];
    const x = hit.start + 1;
    const y = ui.cell.snap(pane.rect.y);
    var first = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &first));

    // Hand jitter turns the pending click into a drag before the second press.
    var jitter = ui.MouseEvent{ .kind = .move, .x = x + 3, .y = y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabDragMouse(workbench, &jitter));
    try std.testing.expect(workbench.editor_drop_target.editor_drag.active);

    var second = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(!terminal_workbench.handleTabDragMouse(workbench, &second));
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &second));
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
        fn symbols(context: *anyopaque, allocator_: Allocator, model: *@import("../vs/editor/common/model/textModel.zig").TextModel, _: CancellationToken) ![]languages.DocumentSymbol {
            const requests: *usize = @ptrCast(@alignCast(context));
            requests.* += 1;
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.enableLanguageFeatures();
    const features = workbench.language_features.?;
    var context: usize = 0;
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

    const pane = @import("../vs/workbench/services/outline/browser/outline.zig").OutlineEditor{
        .context = tab,
        .control = tab.editor,
        .resource = path,
        .language_id = tab.editor.languageId(),
    };
    const outline = (try workbench.outline_service.createOutline(pane, .OutlinePane)).?;
    defer outline.dispose();
    const breadcrumbs = (try workbench.outline_service.createOutline(pane, .Breadcrumbs)).?;
    defer breadcrumbs.dispose();
    try std.testing.expect(!outline.is_empty);
    try std.testing.expect(breadcrumbs.config.collapse_by_default);
    try std.testing.expect(!outline.config.collapse_by_default);
    try std.testing.expect(try workbench.gotoSymbolInEditor());
    try std.testing.expect(workbench.quick_access.isOpen());
    try std.testing.expectEqual(@as(usize, 1), context);
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
    try std.testing.expectEqual(@as(usize, 1), workbench.references_view.history.entries.items.len);
    try workbench.commands.execute("references-view.clearHistory");
    try std.testing.expectEqual(@as(usize, 0), workbench.references_view.history.entries.items.len);

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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &f12));
    try std.testing.expectEqual(@as(usize, 2), tab.editor.modelCursorPosition().lineNumber);

    try tab.editor.setCursorPosition(Position.init(1, 1));
    var shift_f12 = ui.KeyEvent{ .key = .f12, .mods = .{ .shift = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &shift_f12));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const service = try TerminalService.init(allocator, io, .{ .launch = launchTestTerminal });
    try workbench.attachTerminalService(service);

    workbench.newTerminal() catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    // Toggling the panel with a terminal present must not create another.
    try workbench.showTerminal();
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    try workbench.terminal_action_services.showMenu(.switch_instance, workbench.context_menu_api, .{ .x = 1, .y = 1 });
    const switch_menu = workbench.context_menu_service.current.?;
    try std.testing.expectEqual(@as(usize, 1), switch_menu.items.items.len);
    try std.testing.expect(switch_menu.items.items[0].checked);
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .home }));
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .enter }));
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    const panel = workbench.geometry().panelRect();
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
    while (view.hitTest(service, panel, panel_part_mod.titleContentEnd(&workbench.panel_part, panel), panel_part_mod.titleActionsStart(&workbench.panel_part, panel), plus_x, title_y) != .new_terminal) : (plus_x += 1) {
        if (plus_x >= ui.cell.snap(panel.right())) return error.TestUnexpectedResult;
    }
    var move = ui.MouseEvent{ .kind = .move, .x = plus_x, .y = title_y };
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &move));
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    var right = ui.MouseEvent{ .kind = .down, .button = .right, .x = plus_x, .y = title_y };
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &right));
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());

    var click = ui.MouseEvent{ .kind = .down, .button = .left, .x = plus_x, .y = title_y };
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &click));
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
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &tab_move));
    try std.testing.expectEqual(@as(usize, 1), service.group.active);
    var tab_right = ui.MouseEvent{ .kind = .down, .button = .right, .x = ui.cell.snap(with_tabs.tabs.x) + 1, .y = ui.cell.snap(with_tabs.tabs.y) };
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &tab_right));
    try std.testing.expectEqual(@as(usize, 1), service.group.active);
    var escape: ui.KeyEvent = .{ .key = .escape };
    try std.testing.expect(workbench.context_menu_service.handleKey(&escape));
    var tab_click = ui.MouseEvent{ .kind = .down, .button = .left, .x = ui.cell.snap(with_tabs.tabs.x) + 1, .y = ui.cell.snap(with_tabs.tabs.y) };
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &tab_click));
    try std.testing.expectEqual(@as(usize, 0), service.group.active);
}

test "Workbench: wheel scrolls the terminal viewport without moving focus" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const service = try TerminalService.init(allocator, io, .{ .launch = launchTestTerminal });
    try workbench.attachTerminalService(service);
    workbench.newTerminal() catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };

    const instance = service.at(0).?;
    try std.testing.expect(instance.view_focused);
    const content = workbench.terminal_tabbed_view.layoutForService(workbench.geometry().panelRect(), service).terminal;
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
    workbench.setFocus(.editor);
    try std.testing.expect(!instance.view_focused);
    var wheel_up = ui.MouseEvent{
        .kind = .wheel,
        .x = ui.cell.snap(content.x) + 1,
        .y = ui.cell.snap(content.y) + 1,
        .delta_y = -3,
    };
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &wheel_up));
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
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &wheel_down));
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
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &click));
    try std.testing.expect(workbench.focus == .terminal);
    try std.testing.expect(instance.view_focused);
}

test "Workbench: image files open in an image preview tab without touching the file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const tab = workbench.activeTab().?;
    try std.testing.expect(tab.isImage());
    try std.testing.expect(tab.image_input != null);
    try std.testing.expect(tab.file_input == null);
    try std.testing.expect(tab.editor.read_only);
    try std.testing.expectEqualStrings("logo.png", tab.input.getName());

    // No kitty support: the pane renders the message instead of alt/binary text.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    terminal_workbench.setImageProtocol(workbench, .unicode_placeholders);
    terminal_workbench.setCellPixelSize(workbench, 8, 16);
    const tab = workbench.activeTab().?;
    try std.testing.expect(tab.isImage());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
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
    try std.testing.expect(workbench.media_status.?.last.scale != null);
    const scale = tagScale(workbench.media_status.?.last.scale.?);
    try std.testing.expect(scale > 1);

    // The registered Action2 resolves the mounted image pane through the
    // editor service and accepts a zoom value through IQuickInputService.
    try workbench.commands.execute("imagePreview.selectZoomLevel");
    const picker = workbench.quick_access.inputService().pickerRef();
    var zoom_index: ?usize = null;
    for (picker.items.items, 0..) |entry, index| {
        if (entry == .item and std.mem.eql(u8, entry.item.id, "2")) {
            zoom_index = index;
            break;
        }
    }
    picker.setActiveIndex(zoom_index orelse return error.TestExpectedZoomLevel);
    picker.accept();
    try std.testing.expectEqual(@as(f64, 2), tagScale(tab.image_preview.?.currentScale()));

    // Zoomed clicks change the pane's scale too.
    var click = ui.MouseEvent{ .kind = .down, .button = .left, .x = 2, .y = 2 };
    try std.testing.expectEqual(
        @import("../vs/workbench/contrib/mediaPreview/browser/imagePreviewPane.zig").Action.changed,
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    terminal_workbench.setImageProtocol(workbench, .unicode_placeholders);
    const tab = workbench.activeTab().?;
    const pane = tab.image_preview.?;
    const before = pane.editor.load_id;

    var frame_requested = false;
    workbench.frame_scheduler = .{ .context = &frame_requested, .request = struct {
        fn request(ctx: *anyopaque) void {
            const requested: *bool = @ptrCast(@alignCast(ctx));
            requested.* = true;
        }
    }.request };
    workbench.handleFileChanges(&.{.{ .type = .UPDATED, .resource = path }});
    try std.testing.expect(pane.editor.load_id > before);
    try std.testing.expect(frame_requested);

    try workbench.openActiveImageAsText();
    const text_tab = workbench.activeTab().?;
    try std.testing.expect(!text_tab.isImage());
    try std.testing.expectEqualStrings("logo.png", text_tab.input.getName());

    // The typed replacement targets its own group even when the text model
    // is already open in another group, instead of revealing that group.
    const source = workbench.activePane().?;
    _ = try workbench.group_actions.newEmptyGroup(.RIGHT);
    const target = workbench.activePane().?;
    try workbench.openPath(path);
    try std.testing.expect(workbench.activeTab().?.isImage());
    try workbench.commands.execute("imagePreview.openInTextEditor");
    try std.testing.expect(workbench.activePane().? == target);
    try std.testing.expect(!workbench.activeTab().?.isImage());
    try std.testing.expectEqual(@as(usize, 1), target.group.model.count());
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expect(source.activeTab().?.editor.model == workbench.activeTab().?.editor.model);
}

test "Workbench: session serialization restores image tabs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedBinary(allocator, io, &tmp, "logo.png", &test_png_1x1);
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    var file_serializer = FileEditorSerializer.init(allocator, io, 40, 10);
    defer file_serializer.deinit();
    _ = try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, file_serializer.interface());
    var image_serializer = ImagePreviewEditorInputSerializer.init(allocator);
    _ = try registry.registerEditorSerializer(ImagePreviewEditorInput.ID, image_serializer.interface());

    var serialized = try workbench.part.createState(allocator, &registry);
    defer serialized.deinit(allocator);

    const Probe = struct {
        serializer: *ImagePreviewEditorInputSerializer,
        started: bool = false,
        fn create(context: *anyopaque, accessor: @import("../vs/platform/instantiation/common/instantiation.zig").ServicesAccessor) !editor_factory.IEditorSerializer {
            const self: *@This() = @ptrCast(@alignCast(context));
            const lifecycle = try accessor.get(@import("../vs/workbench/services/lifecycle/common/lifecycle.zig").lifecycle_service_id);
            try std.testing.expectEqual(.Ready, lifecycle.phase());
            self.started = true;
            return self.serializer.interface();
        }
    };
    var probe = Probe{ .serializer = &image_serializer };
    var restore_registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer restore_registry.deinit();
    try restore_registry.registerEditorSerializerFactory(ImagePreviewEditorInput.ID, .{ .context = &probe, .create = Probe.create });
    try std.testing.expect(!probe.started);
    try std.testing.expect(restore_registry.getEditorSerializerByType(ImagePreviewEditorInput.ID) == null);
    const restored_window = try TestWindow.initWithOptions(allocator, io, &.{}, 40, 12, .{}, .{ .data = serialized, .registry = &restore_registry });
    const restored = restored_window.workbench;
    defer restored_window.deinit();
    try std.testing.expect(probe.started);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{markdown_path}, 70, 18);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    try workbench.markdown_previews.togglePreview(pane);
    try std.testing.expect(tab.markdown_preview != null);

    // Without placeholder support the alt text is preserved and no image is
    // loaded into the document.
    var plain: std.Io.Writer.Allocating = .init(allocator);
    defer plain.deinit();
    try renderFrame(workbench, &plain.writer);
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

    terminal_workbench.setImageProtocol(workbench, .unicode_placeholders);
    terminal_workbench.setCellPixelSize(workbench, 8, 16);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    // The workbench loads preview images on its background I/O pool.
    for (0..2000) |_| {
        while (workbench.window_events.nextTimeout(time_compat.milliTimestamp(), 1) == 0) _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
        try renderFrame(workbench, &out.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    terminal_workbench.setImageProtocol(workbench, .unicode_placeholders);
    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try renderFrame(workbench, &first.writer);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "a=t,f=100") != null);

    try workbench.commands.execute("workbench.action.closeActiveEditor");
    try std.testing.expect(workbench.images.hasPending());
    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();
    try renderFrame(workbench, &second.writer);
    try std.testing.expect(std.mem.indexOf(u8, second.written(), "a=d,d=I") != null);
}

test "Workbench: interactive open reads on the async Io" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "async-open.txt", "async body");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 40, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    workbench.requestOpenPath(path);
    try std.testing.expect(workbench.editor_opening.pending_open != null);
    try std.testing.expectEqual(@as(usize, 0), workbench.tabCount());

    var waited: usize = 0;
    while (!workbench.window_events.dispatch(time_compat.milliTimestamp()) and waited < 2000) : (waited += 1) {
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 40, 10);
    const workbench = workbench_window.workbench;
    workbench.requestOpenPath(path);
    workbench_window.deinit();
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

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 70, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    workbench.focusSidebar();

    const sidebar = workbench.sidebar.?;
    const link = sidebar.model.roots.items[0].getChild("link").?;
    try std.testing.expect(link.is_directory);
    try std.testing.expect(link.is_symbolic_link);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
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
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &link_click));
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
    try renderFrame(workbench, &out.writer);
    const inner_click = ui.MouseEvent{
        .kind = .down,
        .x = left + 2,
        .y = top + (RowPosition.find(sidebar, inner_item) orelse return error.TestUnexpectedResult),
        .button = .left,
    };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &inner_click));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{seed}, 60, 14);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    workbench.focusSidebar();

    var first_frame: std.Io.Writer.Allocating = .init(allocator);
    defer first_frame.deinit();
    try renderFrame(workbench, &first_frame.writer);

    const sidebar = workbench.sidebar.?;
    const deep = try std.fmt.allocPrint(allocator, "{s}/aaa/bbb/ccc/f11.txt", .{root});
    defer allocator.free(deep);
    try sidebar.revealPath(deep);
    pumpSidebarForTests(workbench);

    var frame: std.Io.Writer.Allocating = .init(allocator);
    defer frame.deinit();
    try renderFrame(workbench, &frame.writer);

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
    try std.testing.expect(try terminal_workbench.handleSidebarKey(workbench, &tab));
    try std.testing.expect(sidebar.tree.stickyScrollFocused());
    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(try terminal_workbench.handleSidebarKey(workbench, &escape));
    try std.testing.expect(!sidebar.tree.stickyScrollFocused());
    try std.testing.expectEqual(Focus.sidebar, workbench.focus);

    // A second Escape leaves the side bar for the editor, as before.
    try std.testing.expect(try terminal_workbench.handleSidebarKey(workbench, &escape));
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.part.group_views.items[0];
    const tab_x = pane.hits.items[0].start + 1;
    const tab_y = ui.cell.snap(pane.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = tab_x, .y = tab_y, .button = .right };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &down));
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expect(workbench.context_menu_service.current != null);
    var release = down;
    release.kind = .up;
    try std.testing.expect(workbench.context_menu_service.handleMouse(&release, &workbench.pointer));
    try std.testing.expect(workbench.context_menu_service.current != null);
    try std.testing.expectEqual(tab_x, workbench.context_menu_service.current.?.popup.?.options.x.?);
    try std.testing.expectEqual(tab_y, workbench.context_menu_service.current.?.popup.?.options.y.?);
    var escape = ui.KeyEvent{ .key = .escape };
    _ = workbench.context_menu_service.handleKey(&escape);

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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 60, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    // The group factory and model update before any terminal frame is drawn.
    const original = workbench.breadcrumbs.activeControl().?;
    try workbench.activateIndex(0);
    try std.testing.expectEqual(original, workbench.breadcrumbs.activeControl().?);
    try std.testing.expectEqualStrings(workbench.activeTab().?.editor.path, original.model.?.resource);
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    try std.testing.expectEqual(@as(usize, 2), workbench.breadcrumbs.factories.count());
    const inactive = workbench.part.group_views.items[0];
    const first = workbench.breadcrumbs.getControl(inactive).?;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    try renderFrame(workbench, &out.writer);
    try std.testing.expectEqual(@as(usize, 2), workbench.breadcrumbs.factories.count());
    try std.testing.expectEqual(first, workbench.breadcrumbs.getControl(inactive).?);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 100, 16);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
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
    try renderFrame(workbench, &out.writer);
    const rendered = try frameText(allocator, &workbench.frame);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "boom") != null);
    const fallback = &workbench.frame.prev;
    for ([_]u32{ '╭', '╮', '╰', '╯' }) |corner| {
        try std.testing.expect(std.mem.indexOfScalar(u32, fallback.cluster, corner) != null);
    }

    workbench.setCellBorderCapabilities(ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,outside,radius\x1b\\").?);
    try renderFrame(workbench, &out.writer);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b, path_c, path_d }, 28, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

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
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &down));
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expect(workbench.context_menu_service.current != null);
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .home }));
    const hidden_name = try allocator.dupe(u8, workbench.context_menu_service.current.?.popup.?.focusedItem().?.label);
    defer allocator.free(hidden_name);

    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.context_menu_service.handleKey(&enter);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b, path_c }, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &down));
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .home }));
    for (0..2) |_| try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .down }));
    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.context_menu_service.handleKey(&enter);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &down));
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .home }));
    for (0..6) |_| try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .down }));
    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.context_menu_service.handleKey(&enter);

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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &down));
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .home }));
    for (0..3) |_| try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .down }));
    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.context_menu_service.handleKey(&enter);
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

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(0);
    try workbench.activeTab().?.editor.insertText("x");
    try std.testing.expect(workbench.activeTab().?.editor.isDirty());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.part.group_views.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = pane.hits.items[0].start + 1,
        .y = ui.cell.snap(pane.rect.y),
        .button = .right,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &down));
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .home }));
    for (0..3) |_| try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .down }));
    var enter = ui.KeyEvent{ .key = .enter };
    _ = workbench.context_menu_service.handleKey(&enter);

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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const pane = workbench.part.group_views.items[0];
    pane.setBreadcrumbsVisible(false);
    pane.setTabsVisible(false);
    pane.layout();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

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

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const tab = workbench.activeTab().?;
    try tab.ensureControllers();
    tab.controllers.?.find.widget().open();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.part.group_views.items[0];
    const top = ui.cell.snap(pane.rect.y) + pane.chromeHeight();
    const row = try workbench.frame.prev.rowText(allocator, top + 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "alpha") != null);
    try std.testing.expectEqual(@as(usize, 1), tab.top_view_zone_rows);

    _ = tab.editor.scrollViewLines(3);
    tab.view.invalidate();
    try renderFrame(workbench, &out.writer);
    try std.testing.expectEqual(@as(usize, 0), tab.top_view_zone_rows);
}

test "startup opens files at the laid-out pane width with one wrapping pass" {
    const allocator = std.testing.allocator;
    const wb_window = try TestWindow.init(allocator, time_compat.io, &.{}, 140, 44);
    const wb = wb_window.workbench;
    defer wb_window.deinit();
    try wb.initSidebarFromWorkspace();
    try wb.openPath("src/tui/workbenchWindow.zig");
    const editor = wb.activeTab().?.editor;
    const pane = wb.activePane().?;
    try std.testing.expectEqual(pane.panes.page_position.?.width, editor.screen_width);
    try std.testing.expect(editor.screen_width < wb.cols);
    try std.testing.expectEqual(@as(usize, 1), editor.view_lines.rebuildAllCount());
}

test "Workbench: markdown preview to the side uses an ordinary editor group and sash" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "source.md", "# First");
    defer allocator.free(path);
    const other = try seedFile(allocator, io, &tmp, "other.md", "# Second");
    defer allocator.free(other);

    for ([_]bool{ false, true }) |borders| {
        const wb_window = try TestWindow.init(allocator, io, &.{path}, 100, 22);
        const wb = wb_window.workbench;
        defer wb_window.deinit();
        wb.setCellBorders(borders);
        const source_group = wb.activePane().?;
        const source = source_group.activeTab().?;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try renderFrame(wb, &out.writer);
        const action = source_group.title_action_hit.?;
        var click = ui.MouseEvent{ .kind = .down, .button = .left, .x = action.start, .y = ui.cell.snap(source_group.rect.y) };
        try std.testing.expect(terminal_workbench.handleTabMouse(wb, &click));
        try std.testing.expectEqual(@as(usize, 2), wb.groupCount());
        const target = wb.activePane().?;
        const preview = target.activeTab().?;
        try std.testing.expect(target != source_group and preview != source);
        try std.testing.expectEqualStrings("Preview source.md", preview.input.getName());
        try std.testing.expectEqualStrings("markdown.preview", preview.input.editor_id.?);
        try std.testing.expect(source.markdown_preview == null);
        try std.testing.expectEqual(source.editor, preview.markdown_preview.?.editor);
        const boundary = ui.cell.snap(source_group.rect.right());
        const y = ui.cell.snap(source_group.rect.y) + source_group.chromeHeight() + 1;
        try std.testing.expect(terminal_workbench.handleSashMouse(wb, &.{ .kind = .down, .button = .left, .x = boundary, .y = y }));
        try std.testing.expect(wb.part.active_sash == wb.part.root);
        try std.testing.expect(terminal_workbench.handleSashMouse(wb, &.{ .kind = .move, .x = boundary + 6, .y = y }));
        try std.testing.expect(terminal_workbench.handleSashMouse(wb, &.{ .kind = .up, .x = boundary + 6, .y = y }));
        try std.testing.expectEqual(boundary + 6, ui.cell.snap(source_group.rect.right()));
        try renderFrame(wb, &out.writer);
        try std.testing.expectEqual(ui.cell.snap(target.rect.w), preview.markdown_preview.?.width);

        try wb.commands.execute("markdown.showSource");
        try std.testing.expectEqual(source_group, wb.activePane().?);
        try source.editor.insertText("LiveEdit");
        while (wb.window_events.nextTimeout(time_compat.milliTimestamp() + 350, 1) == 0) _ = wb.window_events.dispatch(time_compat.milliTimestamp() + 350);
        try renderFrame(wb, &out.writer);
        const rendered = try preview.markdown_preview.?.surface.?.grid().rowText(allocator, 0);
        defer allocator.free(rendered);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "LiveEdit") != null);
        try wb.openPath(other);
        try std.testing.expectEqualStrings("Preview other.md", preview.input.getName());
        try wb.commands.execute("markdown.showPreviewToSide");
        try std.testing.expectEqual(preview, wb.activeTab().?);
        try std.testing.expectEqual(@as(usize, 1), target.count());
        // Closing the active source retargets the unlocked panel to the
        // remaining Markdown tab, just like selecting it explicitly.
        try wb.markdown_previews.showSource();
        _ = try wb.closeActive();
        wb.service.activateGroup(target.group);
        try wb.focusActiveGroup();
        try std.testing.expectEqualStrings("Preview source.md", preview.input.getName());
        try wb.markdown_previews.showSource();
        try std.testing.expect(wb.activeTab().?.file_input != null);
        wb.service.activateGroup(target.group);
        try wb.focusActiveGroup();
        _ = try wb.closeActive();
        try std.testing.expectEqual(@as(usize, 1), wb.groupCount());
        try std.testing.expect(wb.activeTab().?.isMarkdown());
    }
}

test "Workbench: markdown side preview reuses a group below and survives closing its only source" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "persist.md", "# Heading");
    defer allocator.free(path);
    const wb_window = try TestWindow.init(allocator, io, &.{path}, 100, 32);
    const wb = wb_window.workbench;
    defer wb_window.deinit();
    const settings = try seedFile(allocator, io, &tmp, "settings.json", "{\"workbench.editor.openSideBySideDirection\":\"down\"}");
    defer allocator.free(settings);
    try wb.setUserSettingsPaths(&.{settings});
    wb.ensureConfigurationReady();
    const source_group = wb.activePane().?;
    const below = try wb.group_actions.newEmptyGroup(.DOWN);
    wb.service.activateGroup(source_group.group);
    try wb.focusActiveGroup();
    const ctrl_k = ui.KeyEvent{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } };
    const v = ui.KeyEvent{ .key = .{ .char = 'v' } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &ctrl_k));
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &v));
    try std.testing.expectEqual(below, wb.activePane().?);
    try std.testing.expectEqual(@as(usize, 2), wb.groupCount());
    const preview = wb.activeTab().?;
    try wb.markdown_previews.showSource();
    const document = wb.activeTab().?.editor.model;
    _ = try wb.closeActive();
    try std.testing.expectEqual(@as(usize, 1), wb.groupCount());
    try std.testing.expectEqual(preview, wb.activeTab().?);
    try std.testing.expectEqual(document, preview.markdown_preview.?.editor.model);
    try wb.markdown_previews.showSource();
    try std.testing.expect(wb.activeTab().?.isMarkdown());
    try std.testing.expectEqual(document, wb.activeTab().?.editor.model);
}

test "Workbench: breadcrumb symbol filtering survives editor group focus changes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "focus.ts", "one\ntwo");
    defer allocator.free(path);
    const settings = try seedFile(allocator, io, &tmp, "settings.json",
        \\{"breadcrumbs.filePath":"off","breadcrumbs.showFunctions":false}
    );
    defer allocator.free(settings);

    const Symbols = struct {
        fn provide(_: *anyopaque, arena: Allocator, _: *@import("../vs/editor/common/model/textModel.zig").TextModel, _: CancellationToken) ![]languages.DocumentSymbol {
            return arena.dupe(languages.DocumentSymbol, &.{
                .{ .name = "VisibleClass", .kind = 5, .range = Range.init(1, 1, 1, 4), .selection_range = Range.init(1, 1, 1, 4) },
                .{ .name = "HiddenFunction", .kind = 12, .range = Range.init(2, 1, 2, 4), .selection_range = Range.init(2, 1, 2, 4) },
            });
        }
    };

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 100, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setUserSettingsPaths(&.{settings});
    try workbench.enableLanguageFeatures();
    const registration = try workbench.language_features.?.document_symbol_provider.register(.{ .language = "*" }, .{
        .context = workbench,
        .provide_document_symbols = Symbols.provide,
    });
    defer registration.dispose();

    const first = workbench.activePane().?;
    try workbench.splitActive(.horizontal);
    const second = workbench.activePane().?;
    try std.testing.expect(first != second);
    try second.activeTab().?.editor.setCursorPosition(Position.init(2, 1));
    workbench.service.activateGroup(first.group);
    try workbench.focusActiveGroup();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for ([_]*GroupPane{ second, first }) |pane| {
        try workbench.cycleGroup();
        try std.testing.expectEqual(pane, workbench.activePane().?);
        try renderFrame(workbench, &out.writer);
        const row = try workbench.frame.prev.rowText(allocator, 1);
        defer allocator.free(row);
        try std.testing.expect(std.mem.indexOf(u8, row, "VisibleClass") != null);
        try std.testing.expect(std.mem.indexOf(u8, row, "HiddenFunction") == null);
    }
}

test "terminal F1 executes ShowAllCommandsAction through quick input" {
    const workbench_window = try TestWindow.init(std.testing.allocator, std.testing.io, &.{}, 80, 24);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var pending = try ui.input.decodeWithRemainder(std.testing.allocator, "\x1bO");
    defer pending.items.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, pending.consumed);
    for ([_][]const u8{ "\x1bOP", "\x1b[11~" }) |sequence| {
        var decoded = try ui.input.decodeKeys(std.testing.allocator, sequence);
        defer decoded.deinit(std.testing.allocator);
        try std.testing.expectEqual(1, decoded.items.len);
        try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &decoded.items[0]));
        try std.testing.expect(workbench.isQuickAccessOpen());
        try std.testing.expectEqualStrings(">", workbench.quick_access.controller.pickerRef().value.items);
        workbench.quick_access.controller.hide();
    }
}

test "command palette preserves registration order, metadata and editor preconditions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "palette.txt", "palette");
    defer allocator.free(path);
    const workbench_window = try TestWindow.init(allocator, io, &.{}, 80, 24);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const source = workbench.commands.source();
    const empty = try source.get_picks(source.context, allocator);
    defer allocator.free(empty);
    try workbench.openPath(path);
    const editing = try source.get_picks(source.context, allocator);
    defer allocator.free(editing);
    var snapshot: std.Io.Writer.Allocating = .init(allocator);
    defer snapshot.deinit();
    var empty_index: usize = 0;
    var editing_index: usize = 0;
    for (workbench.commands.platform.commands.items) |command| {
        const registration = workbench.commands.getRegistration(command.id) orelse continue;
        const descriptor = registration.descriptor;
        const in_empty = empty_index < empty.len and std.mem.eql(u8, empty[empty_index].command_id, command.id);
        const in_editing = editing_index < editing.len and std.mem.eql(u8, editing[editing_index].command_id, command.id);
        const menu_item = workbench.commands.menus.getMenuItemPtr(@import("../vs/platform/actions/common/actions.zig").menu_ids.CommandPalette, command.id);
        const has_precondition = descriptor.precondition != null or (menu_item != null and menu_item.?.command.precondition != null);
        const entry = .{ command.id, descriptor.title, descriptor.category orelse "", descriptor.tooltip orelse "", registration.isInPalette(), registration.requires_editor, has_precondition, in_empty, in_editing };
        try std.json.Stringify.value(entry, .{}, &snapshot.writer);
        try snapshot.writer.writeByte('\n');
        empty_index += @intFromBool(in_empty);
        editing_index += @intFromBool(in_editing);
    }
    try std.testing.expectEqual(empty.len, empty_index);
    try std.testing.expectEqual(editing.len, editing_index);
    try std.testing.expectEqualStrings(@embedFile("fixtures/workbench-palette.jsonl"), snapshot.written());
}

test "Workbench: clicking a pane body focuses its group" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "click_focus.txt", "alpha\nbeta");
    defer allocator.free(path);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{root});
    defer allocator.free(settings_path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    workbench.ensureConfigurationReady();
    try workbench.splitActive(.horizontal);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const first = workbench.part.group_views.items[0];
    const second = workbench.part.group_views.items[1];
    try std.testing.expect(workbench.activePane().? == second);
    try std.testing.expect(first.tabs_visible and second.tabs_visible);

    // Tabs visible: a press on the group body (not its title control) focuses
    // the group and is translated for the group's active editor.
    var click = ui.MouseEvent{
        .kind = .down,
        .x = ui.cell.snap(first.rect.x) + 2,
        .y = ui.cell.snap(first.rect.y) + first.chromeHeight() + 1,
        .button = .left,
    };
    try std.testing.expect(!terminal_workbench.handleTabMouse(workbench, &click));
    try std.testing.expect(workbench.activePane().? == first);
    try std.testing.expect(workbench.activeTab() == first.activeTab());
    var target = terminal_workbench.editorMouseEvent(workbench, click) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(first.activeTab().?, target.tab);
    try std.testing.expectEqual(@as(usize, 2), target.event.x);
    try std.testing.expectEqual(@as(usize, 1), target.event.y);

    // `workbench.editor.showTabs: single` hides a one-tab strip; the body press
    // must still focus the group (the regression this guards).
    workbench.ensureConfigurationReady();
    try workbench.setUserConfigurationValue("workbench.editor.showTabs", .{ .string = "single" });
    try std.testing.expect(!first.tabs_visible and !second.tabs_visible);

    click = .{
        .kind = .down,
        .x = ui.cell.snap(second.rect.x) + 2,
        .y = ui.cell.snap(second.rect.y) + second.chromeHeight() + 1,
        .button = .left,
    };
    try std.testing.expect(!terminal_workbench.handleTabMouse(workbench, &click));
    try std.testing.expect(workbench.activePane().? == second);
    try std.testing.expect(workbench.activeTab() == second.activeTab());
    target = terminal_workbench.editorMouseEvent(workbench, click) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(second.activeTab().?, target.tab);
    try std.testing.expectEqual(@as(usize, 2), target.event.x);
    try std.testing.expectEqual(@as(usize, 1), target.event.y);
}

test "Workbench: cell borders remove the split gutter" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "border_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "border_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.activateIndex(1);
    try workbench.splitActive(.horizontal);

    const first = workbench.part.group_views.items[0];
    const second = workbench.part.group_views.items[1];
    // The fallback reserves one gutter column between the panes.
    try std.testing.expectEqual(ui.cell.snap(first.rect.right()) + 1, ui.cell.snap(second.rect.x));

    workbench.setCellBorders(true);
    try std.testing.expectEqual(ui.cell.snap(first.rect.right()), ui.cell.snap(second.rect.x));

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const grid = &workbench.frame.prev;
    const left_edge = ui.cell.snap(first.rect.right()) - 1;
    const right_edge = ui.cell.snap(second.rect.x);
    const row: usize = 2;
    const edge = ui.cell_border.Segment;
    const left_stroke = grid.borderSetAt(left_edge, row).strokeAt(edge.right) orelse return error.MissingSashStroke;
    const right_stroke = grid.borderSetAt(right_edge, row).strokeAt(edge.left) orelse return error.MissingSashStroke;
    try std.testing.expect(left_stroke.eql(right_stroke));
    try std.testing.expectEqual(@as(u8, 16), left_stroke.width);
    try std.testing.expectEqual(.centered, left_stroke.placement);
}

test "Workbench: mixed editor splits join inside a single rounded frame" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "round.txt", "text");
    defer allocator.free(path);
    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 24);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const first = workbench.activePane().?;
    try workbench.splitActive(.horizontal);
    _ = try workbench.part.splitGroup(first, .vertical, false);
    workbench.part.layout(workbench.part.viewport);

    const rounded = ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,half,center,palette,round,outside,radius\x1b\\").?;
    const basic = ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,half,center,palette\x1b\\").?;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    for ([_]?ui.cell_border.Capabilities{ null, basic, rounded }) |caps| {
        workbench.setCellBorderCapabilities(caps);
        try renderFrame(workbench, &out.writer);
        const outer = workbench.part.base.bounds.?;
        const x = ui.cell.snap(outer.x);
        const right = ui.cell.snap(outer.right()) - 1;
        const top = ui.cell.snap(outer.y);
        const bottom = ui.cell.snap(outer.bottom()) - 1;
        const sides = workbench.part.root.kind.split;
        const stack = sides.first.kind.split;
        const column = ui.cell.snap(sides.first.rect.right());
        const row = ui.cell.snap(stack.first.rect.bottom());
        const cells = &workbench.frame.prev;
        if (caps) |native| {
            try std.testing.expectEqual(outer, workbench.part.root.rect);
            try std.testing.expectEqual(column, ui.cell.snap(sides.second.rect.x));
            try std.testing.expectEqual(row, ui.cell.snap(stack.second.rect.y));
            const joint = ui.cell_border.Joint;
            const has_round = native.has(.round);
            try std.testing.expectEqual(if (has_round) joint.top_left else 0, cells.borderSetAt(x, top).joints);
            try std.testing.expectEqual(if (has_round) joint.top_right else 0, cells.borderSetAt(right, top).joints);
            try std.testing.expectEqual(if (has_round) joint.bottom_left else 0, cells.borderSetAt(x, bottom).joints);
            try std.testing.expectEqual(if (has_round) joint.bottom_right else 0, cells.borderSetAt(right, bottom).joints);
            const edge = ui.cell_border.Segment;
            const frame_join = cells.borderSetAt(column, top);
            try std.testing.expectEqual(@as(u8, 0), frame_join.joints);
            try std.testing.expect(frame_join.strokeAt(edge.top) != null);
            try std.testing.expect(frame_join.strokeAt(edge.left) != null);
            const split_join = cells.borderSetAt(column - 1, row);
            try std.testing.expectEqual(@as(u8, 0), split_join.joints);
            try std.testing.expect(split_join.strokeAt(edge.top) != null);
            try std.testing.expect(split_join.strokeAt(edge.right) != null);
            try std.testing.expect(cells.borderSetAt(column, row).strokeAt(edge.top) == null);
        } else {
            try std.testing.expectEqual(x + 1, ui.cell.snap(first.rect.x));
            try std.testing.expectEqual(column + 1, ui.cell.snap(sides.second.rect.x));
            try std.testing.expectEqual(row + 1, ui.cell.snap(stack.second.rect.y));
            try std.testing.expectEqual(@as(u32, '╭'), cells.cluster[cells.index(x, top)]);
            try std.testing.expectEqual(@as(u32, '╮'), cells.cluster[cells.index(right, top)]);
            try std.testing.expectEqual(@as(u32, '╰'), cells.cluster[cells.index(x, bottom)]);
            try std.testing.expectEqual(@as(u32, '╯'), cells.cluster[cells.index(right, bottom)]);
            try std.testing.expectEqual(@as(u32, '┬'), cells.cluster[cells.index(column, top)]);
            try std.testing.expectEqual(@as(u32, '┴'), cells.cluster[cells.index(column, bottom)]);
            try std.testing.expectEqual(@as(u32, '├'), cells.cluster[cells.index(x, row)]);
            try std.testing.expectEqual(@as(u32, '┤'), cells.cluster[cells.index(column, row)]);
        }
    }
}

test "Workbench: stacked editor dividers use the editor background and sash color with and without cell borders" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "sash.txt", "text");
    defer allocator.free(path);

    const theme_data = @import("../vs/workbench/services/themes/common/colorThemeData.zig");
    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    const theme = try theme_data.ColorThemeData.createUnloadedTheme(allocator, &registry, "vs-dark", &.{
        .{ "editor.background", "#283038" },
        .{ "editorGroup.border", "#505860" },
        .{ "sash.hoverBorder", "#1267a0" },
    });
    defer theme.deinit();
    const expected_bg = ui.cell.packColor(.{ .r = 0x28, .g = 0x30, .b = 0x38 });
    const expected_idle = ui.cell.packColor(.{ .r = 0x50, .g = 0x58, .b = 0x60 });
    const expected_highlight = ui.cell.packColor(.{ .r = 0x12, .g = 0x67, .b = 0xa0 });

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 24);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    workbench.theme_palette = try allocator.create(theme_colors_mod.ThemeColors);
    workbench.theme_palette.?.* = theme_colors_mod.ThemeColors.init(theme);
    try workbench.splitActive(.vertical);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const split = workbench.part.root.kind.split;
    for ([_]bool{ false, true }) |borders| {
        workbench.setCellBorders(borders);
        const x = ui.cell.snap(split.first.rect.x) + 10;
        const y = ui.cell.snap(split.first.rect.bottom());
        try renderFrame(workbench, &out.writer);
        const cells = &workbench.frame.prev;
        const at = cells.index(x, y);
        const background_at = cells.index(x, if (borders) y - 1 else y);
        const idle_background = cells.bg[background_at];
        if (!borders) {
            try std.testing.expectEqual(@as(u32, '─'), cells.cluster[at]);
            try std.testing.expectEqual(expected_bg, cells.bg[at]);
            try std.testing.expectEqual(expected_idle, cells.fg[at]);
        }

        terminal_workbench.beginMousePointer(workbench);
        try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .move, .x = x, .y = y }));
        try std.testing.expectEqual(ui.Pointer.ns_resize, workbench.pointerShape());
        try renderFrame(workbench, &out.writer);
        try std.testing.expectEqual(expected_highlight, cells.bg[background_at]);
        if (borders) {
            const stroke = cells.borderSetAt(x, y).strokeAt(ui.cell_border.Segment.top) orelse return error.MissingSashStroke;
            try std.testing.expectEqual(@as(u8, 64), stroke.width);
            try std.testing.expectEqual(expected_highlight, ui.cell.packColor(stroke.color.rgb));
        } else {
            try std.testing.expectEqual(expected_bg, cells.fg[at]);
        }

        try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .down, .x = x, .y = y, .button = .left }));
        try renderFrame(workbench, &out.writer);
        try std.testing.expectEqual(expected_highlight, cells.bg[background_at]);
        if (borders) {
            const stroke = cells.borderSetAt(x, y).strokeAt(ui.cell_border.Segment.top) orelse return error.MissingSashStroke;
            try std.testing.expectEqual(expected_highlight, ui.cell.packColor(stroke.color.rgb));
        } else {
            try std.testing.expectEqual(@as(u32, '─'), cells.cluster[at]);
            try std.testing.expectEqual(expected_bg, cells.fg[at]);
        }

        try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .up, .x = x, .y = y, .button = .left }));
        try std.testing.expectEqual(ui.Pointer.ns_resize, workbench.pointerShape());
        terminal_workbench.beginMousePointer(workbench);
        try std.testing.expect(!terminal_workbench.handleSashMouse(workbench, &.{ .kind = .move, .x = x, .y = y - 2 }));
        try std.testing.expectEqual(ui.Pointer.default, workbench.pointerShape());
        try renderFrame(workbench, &out.writer);
        try std.testing.expectEqual(idle_background, cells.bg[background_at]);
        if (borders) {
            const stroke = cells.borderSetAt(x, y).strokeAt(ui.cell_border.Segment.top) orelse return error.MissingSashStroke;
            try std.testing.expectEqual(@as(u8, 16), stroke.width);
            try std.testing.expectEqual(expected_idle, ui.cell.packColor(stroke.color.rgb));
        } else {
            try std.testing.expectEqual(expected_idle, cells.fg[at]);
        }
    }
}

test "Workbench: dropping a tab on a pane edge tiles a new pane" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "drag_split_a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "drag_split_b.txt", "beta");
    defer allocator.free(path_b);

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 50, 10);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    workbench.setCellBorders(true);
    try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.part.group_views.items[0];
    const tab_x = pane.hits.items[0].start;
    const tab_y = ui.cell.snap(pane.rect.y);
    var down = ui.MouseEvent{ .kind = .down, .x = tab_x, .y = tab_y, .button = .left };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &down));

    var move = ui.MouseEvent{
        .kind = .move,
        .x = ui.cell.snap(pane.rect.right()) - 1,
        .y = ui.cell.snap(pane.rect.y) + ui.cell.snap(pane.rect.h) / 2,
        .button = .left,
    };
    try std.testing.expect(terminal_workbench.handleTabMouse(workbench, &move));
    try std.testing.expect(workbench.editor_drop_target.drag_target != null);
    try std.testing.expectEqual(DropZone.right, workbench.editor_drop_target.drag_target.?.zone);

    var up = move;
    up.kind = .up;
    try std.testing.expect(terminal_workbench.handleTabDragMouse(workbench, &up));

    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
    try std.testing.expectEqual(@as(usize, 2), workbench.part.group_views.items.len);
    try std.testing.expectEqual(@as(usize, 2), workbench.tabCount());
    const first = workbench.part.group_views.items[0];
    const second = workbench.part.group_views.items[1];
    try std.testing.expectEqual(ui.cell.snap(first.rect.right()), ui.cell.snap(second.rect.x));
}

test "Workbench: editor drag paints all four destinations and uses the release coordinates" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try seedFile(allocator, io, &tmp, "preview_a.txt", "alpha");
    defer allocator.free(a);
    const b = try seedFile(allocator, io, &tmp, "preview_b.txt", "beta");
    defer allocator.free(b);

    const zones = [_]DropZone{ .right, .left, .top, .bottom };
    for (zones, 0..) |zone, index| {
        const borders = index % 2 == 0;
        const workbench_window = try TestWindow.init(allocator, io, &.{ a, b }, 110, 28);
        const workbench = workbench_window.workbench;
        defer workbench_window.deinit();
        workbench.setCellBorders(borders);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try renderFrame(workbench, &out.writer);

        const pane = workbench.activePane().?;
        const left = ui.cell.snap(pane.rect.x);
        const top = ui.cell.snap(pane.rect.y);
        const right = ui.cell.snap(pane.rect.right());
        const bottom = ui.cell.snap(pane.rect.bottom());
        const center_x = (left + right) / 2;
        const center_y = (top + bottom) / 2;
        const tab_x = pane.hits.items[0].start;
        const dragged = pane.tabAtIndex(allocator, pane.hits.items[0].index).?;
        const edge_x = switch (zone) {
            .left => left,
            .right => right - 1,
            else => center_x,
        };
        const edge_y = switch (zone) {
            .top => top + pane.titleHeight(),
            .bottom => bottom - 1,
            else => center_y,
        };
        const before = workbench.frame.prev.bg[workbench.frame.prev.index(center_x, center_y)];

        try sendDragMouse(workbench, 0, tab_x, top, false);
        try sendDragMouse(workbench, 32, edge_x, edge_y, false);
        if (workbench.editor_drop_target.drag_target) |*overlay| overlay.fade_start -= 150;
        const overlay = workbench.editor_drop_target.drag_target orelse return error.MissingDropOverlay;
        try std.testing.expectEqual(zone, overlay.zone);
        try std.testing.expect(workbench.editor_drop_target.editor_drag.data_transfer.image != null);
        try renderFrame(workbench, &out.writer);

        const sample_x = ui.cell.snap(overlay.rect.x + overlay.rect.w / 3);
        const sample_y = ui.cell.snap(overlay.rect.y + overlay.rect.h / 3);
        const highlighted = workbench.frame.prev.bg[workbench.frame.prev.index(sample_x, sample_y)];
        try std.testing.expect(highlighted != before);

        if (zone == .right) {
            // Release on the opposite edge without an intervening move.
            try sendDragMouse(workbench, 0, left, center_y, true);
            const destination = workbench.activePane().?;
            try std.testing.expect(destination.activeTab() == dragged);
            try std.testing.expect(destination.rect.x < pane.rect.x);
        } else {
            try sendDragMouse(workbench, 0, edge_x, edge_y, true);
            const destination = workbench.activePane().?;
            try std.testing.expect(destination.activeTab() == dragged);
            try std.testing.expectEqual(overlay.rect.x, destination.rect.x);
            try std.testing.expectEqual(overlay.rect.w, destination.rect.w);
            try std.testing.expectEqual(overlay.rect.bottom(), destination.rect.bottom());
        }
        try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
        try std.testing.expect(workbench.editor_drop_target.drag_target == null and workbench.editor_drop_target.editor_drag.source == null);
    }
}

test "Workbench: editor drag keeps range selection and cancels on source removal" {
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
    const workbench_window = try TestWindow.init(allocator, io, &.{ a, b, c }, 100, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const pane = workbench.activePane().?;
    const y = ui.cell.snap(pane.rect.y);
    try sendDragMouse(workbench, 0, pane.hits.items[0].start, y, false);
    try sendDragMouse(workbench, 0, pane.hits.items[0].start, y, true);
    try sendDragMouse(workbench, 4, pane.hits.items[1].start, y, false);
    try sendDragMouse(workbench, 4, pane.hits.items[1].start, y, true);

    const edge_x = ui.cell.snap(pane.rect.right()) - 1;
    const center_y = ui.cell.snap(pane.rect.y + pane.rect.h / 2);
    try sendDragMouse(workbench, 0, pane.hits.items[1].start, y, false);
    try sendDragMouse(workbench, 32, edge_x, center_y, false);
    const dragged = workbench.editor_drop_target.editor_drag.data_transfer.payload.?;
    try std.testing.expectEqual(@as(usize, 2), dragged.len);
    try std.testing.expect(dragged[0] == pane.tabAtIndex(allocator, 0).?);
    try std.testing.expect(dragged[1] == pane.tabAtIndex(allocator, 1).?);
    try sendDragMouse(workbench, 0, edge_x, center_y, true);
    const destination = workbench.activePane().?;
    try std.testing.expectEqual(@as(usize, 2), destination.tabs.items.len);
    try std.testing.expectEqualStrings("a.txt", destination.tabAtIndex(allocator, 0).?.input.getName());
    try std.testing.expectEqualStrings("b.txt", destination.tabAtIndex(allocator, 1).?.input.getName());

    workbench.editor_drop_target.last_tab_click = null;
    try renderFrame(workbench, &out.writer);
    const source_tab = destination.tabAtIndex(allocator, 0).?;
    const hit = destination.hits.items[0];
    try sendDragMouse(workbench, 0, hit.start, ui.cell.snap(destination.rect.y), false);
    try sendDragMouse(workbench, 32, edge_x, center_y, false);
    try std.testing.expect(workbench.editor_drop_target.editor_drag.active);
    _ = try workbench.closePath(source_tab.editor.path);
    try std.testing.expect(workbench.editor_drop_target.editor_drag.source == null and workbench.editor_drop_target.drag_target == null);
    try sendDragMouse(workbench, 0, edge_x, center_y, true);
    try std.testing.expectEqual(@as(usize, 2), workbench.groupCount());
}

test "Workbench: bottom panel has a rounded outline with and without cell borders" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workbench_window = try TestWindow.init(allocator, io, &.{}, 90, 24);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.showProblems();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const caps = ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,outside,radius\x1b\\").?;
    for ([_]bool{ false, true }) |native| {
        workbench.setCellBorderCapabilities(if (native) caps else null);
        try renderFrame(workbench, &out.writer);

        const cells = &workbench.frame.prev;
        const left = ui.cell.snap(workbench.part.base.bounds.?.x);
        const right = workbench.cols - 1;
        const top = ui.cell.snap(workbench.part.base.bounds.?.h);
        const bottom = ui.cell.snap(workbench.geometry().statusBarRect().y) - 1;
        const joint = ui.cell_border.Joint;
        const corners = [_]struct { x: usize, y: usize, glyph: u32, round_joint: u8 }{
            .{ .x = left, .y = top, .glyph = '╭', .round_joint = joint.top_left },
            .{ .x = right, .y = top, .glyph = '╮', .round_joint = joint.top_right },
            .{ .x = left, .y = bottom, .glyph = '╰', .round_joint = joint.bottom_left },
            .{ .x = right, .y = bottom, .glyph = '╯', .round_joint = joint.bottom_right },
        };
        for (corners) |corner| {
            if (native) {
                try std.testing.expectEqual(corner.round_joint, cells.borderSetAt(corner.x, corner.y).joints);
            } else {
                try std.testing.expectEqual(corner.glyph, cells.cluster[cells.index(corner.x, corner.y)]);
            }
        }

        const inset: usize = if (native) 0 else 1;
        const title = try cells.rowText(allocator, top + inset);
        defer allocator.free(title);
        try std.testing.expect(std.mem.indexOf(u8, title, "PROBLEMS") != null);
        const content = workbench.geometry().panelContentRect();
        try std.testing.expectEqual(left + inset, ui.cell.snap(content.x));
        try std.testing.expectEqual(top + inset + 1, ui.cell.snap(content.y));
        try std.testing.expectEqual(bottom + 1 - inset, ui.cell.snap(content.bottom()));
    }

    workbench.setCellBorderCapabilities(null);
    try workbench.resize(90, 7);
    try renderFrame(workbench, &out.writer);
    const title = try workbench.frame.prev.rowText(allocator, ui.cell.snap(workbench.part.base.bounds.?.h));
    defer allocator.free(title);
    try std.testing.expect(std.mem.indexOf(u8, title, "PROBLEMS") != null);
    try std.testing.expect(workbench.geometry().panelContentRect().h >= 1);
}

test "Workbench: zen mode applies configuration changes while active" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "zen_config.txt", "alpha\nbeta\n");
    defer allocator.free(path);

    var settings_file = try tmp.dir.createFile(io, "zen-live-settings.json", .{});
    try settings_file.writeStreamingAll(io, "{}");
    settings_file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/zen-live-settings.json", .{buffer[0..root_len]});
    defer allocator.free(settings_path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.setUserConfigurationValue("editor.lineNumbers", .{ .string = "relative" });

    const tab = workbench.activeTab().?;
    try std.testing.expectEqual(editor_options.RenderLineNumbersType.Relative, tab.view.terminal_view_host.options.get(.lineNumbers).render_type);

    try std.testing.expect(workbench.notification_api.getFilter(null) == .OFF);
    try workbench.toggleZenMode(false, false);
    try std.testing.expect(workbench.notification_api.getFilter(null) == .ERROR);
    try workbench.setUserConfigurationValue("zenMode.silentNotifications", .{ .bool = false });
    try std.testing.expect(workbench.notification_api.getFilter(null) == .OFF);
    try workbench.setUserConfigurationValue("zenMode.silentNotifications", .{ .bool = true });
    try std.testing.expect(workbench.notification_api.getFilter(null) == .ERROR);
    try workbench.setUserConfigurationValue("workbench.notifications.position", .{ .string = "bottom-left" });
    try std.testing.expect(workbench.core.notification_controller.?.position == .bottom_left);
    try std.testing.expectEqual(editor_options.RenderLineNumbersType.Off, tab.view.terminal_view_host.options.get(.lineNumbers).render_type);
    try std.testing.expect(workbench.layout.isMainEditorCentered());
    try std.testing.expect(!workbench.geometry().statusBarVisible());
    try std.testing.expect(!workbench.activity_bar_part.visible);

    try workbench.setUserConfigurationValue("zenMode.hideLineNumbers", .{ .bool = false });
    try std.testing.expectEqual(editor_options.RenderLineNumbersType.Relative, tab.view.terminal_view_host.options.get(.lineNumbers).render_type);

    try workbench.setUserConfigurationValue("zenMode.hideStatusBar", .{ .bool = false });
    try std.testing.expect(workbench.geometry().statusBarVisible());

    try workbench.setUserConfigurationValue("zenMode.hideActivityBar", .{ .bool = false });
    try std.testing.expect(workbench.activity_bar_part.visible);

    try workbench.setUserConfigurationValue("zenMode.centerLayout", .{ .bool = false });
    try std.testing.expect(!workbench.layout.isMainEditorCenteredEffective());

    try workbench.toggleZenMode(false, false);
    try std.testing.expect(!workbench.layout.isZenModeActive());
    try std.testing.expect(workbench.notification_api.getFilter(null) == .OFF);
    try std.testing.expectEqual(editor_options.RenderLineNumbersType.Relative, tab.view.terminal_view_host.options.get(.lineNumbers).render_type);
    try std.testing.expect(workbench.geometry().statusBarVisible());
    try std.testing.expect(workbench.activity_bar_part.visible);

    // Exiting zen uses the current workbench preference, including an edit
    // made after entry while the status bar was temporarily hidden.
    try workbench.notification_api.setFilter(.{ .global = .ERROR });
    try workbench.commands.execute(zen_mode_contribution.toggle_zen_mode_id);
    try workbench.setUserConfigurationValue("workbench.statusBar.visible", .{ .bool = false });
    try workbench.commands.execute(zen_mode_contribution.exit_zen_mode_id);
    try std.testing.expect(workbench.notification_api.getFilter(null) == .ERROR);
    try std.testing.expect(!workbench.geometry().statusBarVisible());
}

test "Workbench: centered layout narrows and centers the editor part" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "centered.txt", "alpha\n");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    const area = workbench.part.base.bounds.?;
    try workbench.commands.execute("workbench.action.toggleCenteredLayout");
    try std.testing.expect(workbench.layout.isMainEditorCentered());
    try std.testing.expect(workbench.layout.isMainEditorCenteredEffective());
    const centered = workbench.part.viewport;
    try std.testing.expect(centered.w < area.w);
    try std.testing.expect(centered.x > area.x);
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try renderFrame(workbench, &rendered.writer);
    const pane_rect = workbench.activePane().?.rect;
    try std.testing.expect(pane_rect.x >= centered.x);
    try std.testing.expect(pane_rect.x + pane_rect.w <= centered.x + centered.w);

    _ = try workbench.group_actions.newEmptyGroup(.DOWN);
    try std.testing.expect(workbench.layout.isMainEditorCenteredEffective());
    _ = try workbench.group_actions.newEmptyGroup(.RIGHT);
    try std.testing.expect(workbench.layout.isMainEditorCentered());
    try std.testing.expect(!workbench.layout.isMainEditorCenteredEffective());
    workbench.part.arrangeGroups(.MAXIMIZE);
    try std.testing.expect(workbench.layout.isMainEditorCenteredEffective());
    workbench.part.restoreGroupSizes();
    try std.testing.expect(!workbench.layout.isMainEditorCenteredEffective());

    try workbench.commands.execute("workbench.action.toggleCenteredLayout");
    try std.testing.expect(!workbench.layout.isMainEditorCentered());
    try std.testing.expectEqual(area.w, workbench.part.viewport.w);
}

test "Workbench: activity bar top moves the composite bar into the side bar" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    var settings = try tmp.dir.createFile(io, ".vscode/settings.json", .{});
    try settings.writeStreamingAll(io, "{\"workbench.activityBar.location\": \"top\"}");
    settings.close(io);

    const path = try seedFile(allocator, io, &tmp, "top_bar.txt", "alpha\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 70, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);

    // The rail is gone and the side bar takes the left column.
    try std.testing.expectEqual(@as(usize, 0), ui.cell.snap(workbench.activity_bar_part.base.bounds.?.w));
    try std.testing.expect(workbench.sidebar_part.shouldShowCompositeBar());
    try std.testing.expectEqual(@as(usize, 29), ui.cell.snap(workbench.part.base.bounds.?.x));

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    // Row 0 is the composite bar, row 1 the title label, row 2 the content.
    const grid = workbench.frame.present();
    try std.testing.expectEqual(@as(u32, '\u{f07b}'), grid.cluster[grid.index(1, 0)]);
    try std.testing.expectEqual(@as(u32, '\u{f002}'), grid.cluster[grid.index(4, 0)]);
    const title_row = try grid.rowText(allocator, 1);
    defer allocator.free(title_row);
    try std.testing.expect(std.mem.indexOf(u8, title_row, "EXPLORER") != null);
    // The tree is the first thing below the title (`.vscode` sorts first).
    var found_file = false;
    for (2..5) |row| {
        const content_row = try workbench.frame.present().rowText(allocator, row);
        defer allocator.free(content_row);
        if (std.mem.indexOf(u8, content_row, "top_bar.txt") != null) found_file = true;
    }
    try std.testing.expect(found_file);

    // Clicking a composite bar item switches the view container.
    const search_click = ui.MouseEvent{ .kind = .down, .x = 4, .y = 0 };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &search_click));
    try std.testing.expectEqual(@as(usize, 1), workbench.activeActivity());

    out.clearRetainingCapacity();
    try renderFrame(workbench, &out.writer);
    const search_title = try workbench.frame.present().rowText(allocator, 1);
    defer allocator.free(search_title);
    try std.testing.expect(std.mem.indexOf(u8, search_title, "SEARCH") != null);
}

test "Workbench: list commands follow last focused list without a render or activity scan" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "last-list.txt", "alpha");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const window = try TestWindow.init(allocator, io, &.{path}, 80, 20);
    defer window.deinit();
    const wb = window.workbench;
    try wb.initSidebar(root);
    pumpSidebarForTests(wb);
    wb.focusSidebar();
    const explorer = wb.sidebar.?;
    try std.testing.expect(wb.lists.lastFocusedList().?.focus == &explorer.list_focus);
    try wb.showActivity(1); // the search input, not the results list
    try std.testing.expect(wb.lists.lastFocusedList().?.focus == &explorer.list_focus);
    try wb.commands.execute("list.focusLast");
    try std.testing.expect(explorer.selectedNode() != null);
    const search = wb.search_window.view.?;
    search.focusResults();
    try std.testing.expect(wb.lists.lastFocusedList().?.focus == &search.list_focus);
    wb.focusEditor();
    try std.testing.expect(wb.lists.lastFocusedList().?.focus == &search.list_focus);
    try wb.setWorkspaceFolders(&.{root});
    try std.testing.expect(wb.lists.lastFocusedList() == null);
}

test "Workbench: panel positions, alignment and orthogonal sash sizes follow Layout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "panel-position.txt", "editor-position-content");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const window = try TestWindow.init(allocator, io, &.{path}, 100, 26);
    defer window.deinit();
    const wb = window.workbench;
    try wb.initSidebar(root);
    pumpSidebarForTests(wb);
    _ = try wb.openPanelContainer(PROBLEMS_CONTAINER_ID);
    try wb.layout_api.setSize(.panel, .{ .height = 6 });
    try wb.commands.execute("workbench.action.positionPanelTop");
    var rects = wb.geometry().workbenchGridLayout();
    try std.testing.expectEqual(@as(f64, 6), rects.panel.h);
    try std.testing.expectEqual(rects.panel.bottom(), rects.editor.y);
    try std.testing.expectEqual(rects.panel.w, rects.editor.w);
    try std.testing.expectEqual(.top, wb.panel_part.getPosition());
    wb.focusEditor();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(wb, &out.writer);
    const cursor = terminal_workbench.cursorCell(wb) orelse return error.TestExpectedCursor;
    try std.testing.expect(cursor.row >= ui.cell.snap(rects.editor.y));
    try wb.commands.execute("workbench.action.positionPanelRight");
    try wb.layout_api.setSize(.panel, .{ .width = 24 });
    rects = wb.geometry().workbenchGridLayout();
    try std.testing.expectEqual(rects.editor.right(), rects.panel.x);
    try std.testing.expectEqual(@as(f64, 24), rects.panel.w);
    try std.testing.expectEqual(rects.editor.h, rects.panel.h);
    const x = ui.cell.snap(rects.panel.x);
    const y = ui.cell.snap(rects.panel.y) + 4;
    try std.testing.expectEqual(@import("../vs/workbench/browser/layout.zig").WorkbenchGrid.Sash.panel, terminal_workbench.workbenchSashAt(wb, x, y).?);
    try std.testing.expectEqual(ui.Pointer.ew_resize, terminal_workbench.workbenchSashPointer(wb, .panel));
    try std.testing.expect(terminal_workbench.handleWorkbenchSashMouse(wb, &.{ .kind = .down, .button = .left, .x = x, .y = y }));
    try std.testing.expect(terminal_workbench.handleWorkbenchSashMouse(wb, &.{ .kind = .move, .button = .left, .x = x - 3, .y = y }));
    try std.testing.expect(terminal_workbench.handleWorkbenchSashMouse(wb, &.{ .kind = .up, .button = .left, .x = x - 3, .y = y }));
    try std.testing.expectEqual(@as(f64, 27), wb.geometry().workbenchGridLayout().panel.w);
    try wb.commands.execute("workbench.action.positionPanelLeft");
    rects = wb.geometry().workbenchGridLayout();
    try std.testing.expectEqual(rects.panel.right(), rects.editor.x);
    try std.testing.expectEqual(@as(f64, 27), rects.panel.w);
    try wb.commands.execute("workbench.action.positionPanelBottom");
    rects = wb.geometry().workbenchGridLayout();
    try std.testing.expectEqual(@as(f64, 6), rects.panel.h);
    try wb.commands.execute("workbench.action.alignPanelJustify");
    rects = wb.geometry().workbenchGridLayout();
    try std.testing.expectEqual(rects.sidebar.x, rects.panel.x);
    try std.testing.expectEqual(rects.editor.right(), rects.panel.right());
    try std.testing.expectEqual(rects.editor.bottom(), rects.sidebar.bottom());
    const keys = (try wb.ensureContextKeys()).interface();
    try std.testing.expectEqualStrings("justify", keys.getContextKeyValue("panelAlignment").string);
    try std.testing.expectEqualStrings("bottom", keys.getContextKeyValue("panelPosition").string);
    const profile = wb.layout.profileState();
    try std.testing.expectEqual(@as(?usize, 27), profile.@"panel.lastNonMaximizedWidth");
    try std.testing.expectEqual(@as(?usize, 6), profile.@"panel.lastNonMaximizedHeight");
    try wb.commands.execute("workbench.action.alignPanelCenter");
    try wb.commands.execute("workbench.action.toggleMaximizedPanel");
    try std.testing.expect(wb.layout_api.isPanelMaximized());
    try wb.commands.execute("workbench.action.alignPanelLeft");
    try std.testing.expect(!wb.layout_api.isPanelMaximized());
    try std.testing.expect(wb.layout_api.isVisible(.editor));
    try wb.commands.execute("workbench.action.positionPanelRight");
    try wb.commands.execute("workbench.action.toggleMaximizedPanel");
    try std.testing.expect(wb.layout_api.isPanelMaximized());
    try wb.commands.execute("workbench.action.positionPanelTop");
    try std.testing.expect(!wb.layout_api.isPanelMaximized());
    try std.testing.expectEqual(@as(f64, 6), wb.geometry().workbenchGridLayout().panel.h);
}

test "Workbench: maximize panel hides editor and restores remembered height and visibility" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "panel-max.txt", "editor-only-content");
    defer allocator.free(path);
    const settings = try seedFile(allocator, io, &tmp, "panel-settings.json", "{}");
    defer allocator.free(settings);
    const window = try TestWindow.init(allocator, io, &.{path}, 80, 24);
    defer window.deinit();
    const wb = window.workbench;
    try wb.setUserSettingsPaths(&.{settings});
    _ = try wb.openPanelContainer(PROBLEMS_CONTAINER_ID);
    try wb.layout_api.setSize(.panel, .{ .height = 8 });
    const before = wb.geometry().panelHeight();
    try wb.commands.execute("workbench.action.toggleMaximizedPanel");
    try std.testing.expect(wb.layout_api.isPanelMaximized());
    const keys = (try wb.ensureContextKeys()).interface();
    try std.testing.expect(keys.getContextKeyValue("panelMaximized").boolean);
    try std.testing.expect(!keys.getContextKeyValue("mainEditorAreaVisible").boolean);
    try std.testing.expect(!wb.layout_api.isVisible(.editor));
    try std.testing.expectEqual(wb.geometry().workbenchRows(), wb.geometry().panelHeight());
    try std.testing.expectEqual(@as(usize, 0), wb.layout_api.getSize(.editor).height);
    try std.testing.expectEqual(Focus.problems, wb.focus);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(wb, &out.writer);
    const frame = try frameText(allocator, &wb.frame);
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "editor-only-content") == null);
    try wb.commands.execute("workbench.action.toggleMaximizedPanel");
    try std.testing.expect(wb.layout_api.isVisible(.editor));
    try std.testing.expectEqual(before, wb.geometry().panelHeight());
    try wb.commands.execute("workbench.action.toggleMaximizedPanel");
    try wb.commands.execute("workbench.action.closePanel");
    try std.testing.expect(wb.layout_api.isVisible(.editor));
    try std.testing.expect(!wb.layout_api.isVisible(.panel));
    _ = try wb.openPanelContainer(PROBLEMS_CONTAINER_ID);
    try std.testing.expect(wb.layout_api.isPanelMaximized());
    try wb.commands.execute("workbench.action.closePanel");
    try wb.setUserConfigurationValue("workbench.panel.opensMaximized", .{ .string = "never" });
    _ = try wb.openPanelContainer(PROBLEMS_CONTAINER_ID);
    try std.testing.expect(!wb.layout_api.isPanelMaximized());
    try std.testing.expectEqual(before, wb.geometry().panelHeight());
}

test "Workbench: closing the side bar keeps the activity bar" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "rail_closed.txt", "alpha\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 70, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    const grid = workbench.frame.present();
    try std.testing.expectEqual(@as(u32, '\u{f07b}'), grid.cluster[grid.index(1, 1)]);

    _ = try workbench.commands.execute("workbench.action.closeSidebar");
    try std.testing.expect(!workbench.sidebar_part.isVisible());
    try std.testing.expect(workbench.sidebar_part.activePaneComposite() == null);
    try std.testing.expectEqualStrings("explorer", workbench.sidebar_part.pane.last_active_id.?);
    try std.testing.expectEqual(@as(usize, 3), ui.cell.snap(workbench.part.base.bounds.?.x));

    // The activity bar stays visible and clickable while the side bar is
    // closed; an entry click reveals the side bar again.
    out.clearRetainingCapacity();
    try renderFrame(workbench, &out.writer);
    const closed_grid = workbench.frame.present();
    try std.testing.expectEqual(@as(u32, '\u{f07b}'), closed_grid.cluster[closed_grid.index(1, 1)]);
    const rail_click = ui.MouseEvent{ .kind = .down, .x = 1, .y = 1 };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &rail_click));
    try std.testing.expect(workbench.sidebar_part.isVisible());

    try workbench.showActivity(1);
    try std.testing.expectEqualStrings("search", workbench.sidebar_part.activePaneComposite().?.id);
    _ = try workbench.commands.execute("workbench.action.closeSidebar");
    try std.testing.expect(workbench.sidebar_part.activePaneComposite() == null);
    _ = try workbench.commands.execute("workbench.action.focusSideBar");
    try std.testing.expectEqualStrings("search", workbench.sidebar_part.activePaneComposite().?.id);
    try std.testing.expect(workbench.sidebar_part.isVisible());
    try std.testing.expectEqual(Focus.sidebar, workbench.focus);

    // The owner navigation actions use Layout's visible grid neighbors; they
    // leave an editor group at the outer edge and return to its last focus.
    try workbench.commands.execute("workbench.action.navigateRight");
    try std.testing.expectEqual(Focus.editor, workbench.focus);
    try workbench.commands.execute("workbench.action.navigateLeft");
    try std.testing.expectEqual(Focus.sidebar, workbench.focus);
}

test "Workbench: status bar escape clears the hover tooltip" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "status_escape.txt", "alpha");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const part = workbench.statusbar.main_part;
    const entry = part.model.entries()[0];
    workbench.focusStatusBar();
    part.setHovered(entry.handle);
    try std.testing.expect(part.hovered != null);

    try std.testing.expect(try terminal_workbench.handleStatusbarKey(workbench, &.{ .key = .escape }));
    try std.testing.expect(part.hovered == null);
}

test "Workbench: external file changes reload clean editors only" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "external.txt", "before");
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 40, 9);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();

    const tab = workbench.activeTab().?;

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "after" });
    workbench.handleFileChanges(&.{.{ .type = .UPDATED, .resource = path }});
    var reload_guard: usize = 0;
    while (workbench.editor_opening.reload_jobs.items.len != 0 and reload_guard < 2000) : (reload_guard += 1) {
        _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(reload_guard < 2000);
    var reloaded = try tab.editor.model.getValue(.TextDefined, true);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings("after", reloaded.items);

    // Dirty editors keep the in-memory content.
    try tab.editor.insertText("local ");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "external" });
    workbench.handleFileChanges(&.{.{ .type = .UPDATED, .resource = path }});
    var preserved = try tab.editor.model.getValue(.TextDefined, true);
    defer preserved.deinit();
    try std.testing.expectEqualStrings("local after", preserved.items);
    try std.testing.expect(tab.editor.hasConflict());
    try std.testing.expect(std.mem.indexOf(u8, tab.editor.message(), "Conflict") != null);
    try tab.editor.save();
    try std.testing.expect(!tab.editor.hasConflict());
    try std.testing.expect(std.mem.indexOf(u8, tab.editor.message(), "Saved") != null);
}

test "Workbench: terminal splits share one group and preserve panel geometry on resize" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workbench_window = try TestWindow.init(allocator, io, &.{}, 96, 24);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const service = try TerminalService.init(allocator, io, .{ .launch = launchTestTerminal });
    try workbench.attachTerminalService(service);
    const keys = try workbench.ensureContextKeys();
    try std.testing.expectEqual(@as(f64, 0), keys.getValue("terminalCount").number);
    workbench.commands.execute(terminal_ids.new) catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };

    try workbench.commands.execute(terminal_ids.split);
    try std.testing.expectEqual(@as(usize, 1), service.group.groupCount());
    try std.testing.expectEqual(@as(usize, 2), service.count());
    try std.testing.expectEqual(@as(f64, 2), keys.getValue("terminalCount").number);
    try std.testing.expectEqual(@as(f64, 1), keys.getValue("terminalGroupCount").number);
    try std.testing.expect(keys.getValue("terminalSplitPaneActive").boolean);
    try std.testing.expect(keys.getValue("terminalViewShowing").boolean);
    const source = workbench.commands.source();
    const picks = try source.get_picks(source.context, allocator);
    defer allocator.free(picks);
    try std.testing.expect(for (picks) |pick| {
        if (std.mem.eql(u8, pick.command_id, terminal_ids.focus_next_pane)) break true;
    } else false);
    const view = &workbench.terminal_tabbed_view;
    const layout = view.layoutForService(workbench.geometry().panelRect(), service);
    const first = service.group.paneRect(layout.terminal, 0);
    const second = service.group.paneRect(layout.terminal, 1);
    try std.testing.expectEqual(first.right() + 1, second.x);
    try std.testing.expectEqual(layout.terminal.right(), second.right());
    try std.testing.expectEqual(ui.cell.snap(first.w), service.at(0).?.cols);

    const divider = ui.cell.snap(first.right());
    const y = ui.cell.snap(first.y);
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &.{ .kind = .down, .button = .left, .x = divider, .y = y }));
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &.{ .kind = .move, .button = .left, .x = divider + 5, .y = y }));
    try std.testing.expect(terminal_workbench.handleTerminalMouse(workbench, &.{ .kind = .up, .button = .left, .x = divider + 5, .y = y }));
    try std.testing.expect(service.at(0).?.cols > ui.cell.snap(first.w));
    try std.testing.expect(service.at(1).?.cols < ui.cell.snap(second.w));

    const first_instance = service.at(0).?;
    const second_instance = service.at(1).?;
    try service.group.unsplitInstance(1);
    try std.testing.expectEqual(@as(usize, 2), service.group.groupCount());
    try std.testing.expectEqual(@as(f64, 2), keys.getValue("terminalGroupCount").number);
    try std.testing.expect(!keys.getValue("terminalSplitPaneActive").boolean);
    try service.group.joinInstances(&.{ first_instance, second_instance });
    try std.testing.expectEqual(@as(usize, 1), service.group.groupCount());
    try std.testing.expectEqual(first_instance, service.active().?);
}

test "terminal host flushes final output and fires one exit before removing panel and editor instances" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const Exit = @import("../vs/platform/terminal/node/pty.zig").Exit;
    const Observer = struct {
        service: *TerminalService,
        instance: *terminal_service_mod.TerminalInstance,
        count: usize = 0,
        code: ?i32 = null,
        saw_final_output: bool = false,
        still_registered: bool = false,

        fn onExit(exit: Exit, self: *@This()) !void {
            self.count += 1;
            self.code = exit.code;
            self.saw_final_output = std.mem.eql(u8, self.instance.sequence orelse "", "last-output");
            self.still_registered = self.service.getInstanceFromId(self.instance.id) == self.instance;
        }
    };
    const workbench_window = try TestWindow.init(std.testing.allocator, std.testing.io, &.{}, 80, 24);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var host = try @import("workbench.zig").TerminalHostLoop.init(workbench, &output.writer, null, null);
    defer host.deinit();
    const script = "read line; printf '\\033]2;last-output\\007'; exit ";
    const editor = workbench.launchTerminalProcess("editor", "/bin/sh", &.{ "-c", script ++ "17" }, null) catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };
    try workbench.commands.execute(terminal_ids.move_to_editor);
    const panel = try workbench.launchTerminalProcess("panel", "/bin/sh", &.{ "-c", script ++ "0" }, null);
    const service = workbench.terminal_service.?;
    try std.testing.expectEqual(@as(usize, 1), service.editor.instances.items.len);
    var editor_exit = Observer{ .service = service, .instance = editor };
    var panel_exit = Observer{ .service = service, .instance = panel };
    try editor.onExit.event(&editor_exit, Observer.onExit);
    try panel.onExit.event(&panel_exit, Observer.onExit);
    editor.writeInput("\n");
    panel.writeInput("\n");
    const deadline = time_compat.milliTimestamp() + 5000;
    while (workbench.terminalCount() != 0 and time_compat.milliTimestamp() < deadline) _ = try host.wait(1000);
    try std.testing.expectEqual(@as(usize, 0), workbench.terminalCount());
    try std.testing.expectEqual(@as(?i32, 17), editor_exit.code);
    try std.testing.expectEqual(@as(?i32, 0), panel_exit.code);
    for ([_]Observer{ editor_exit, panel_exit }) |observer| {
        try std.testing.expectEqual(@as(usize, 1), observer.count);
        try std.testing.expect(observer.saw_final_output);
        try std.testing.expect(observer.still_registered);
    }
}

test "duplicate tab names with identical parent names show their distinguishing directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const left = try seedFile(allocator, io, &tmp, "left/src/main.txt", "left");
    defer allocator.free(left);
    const right = try seedFile(allocator, io, &tmp, "right/src/main.txt", "right");
    defer allocator.free(right);
    const workbench_window = try TestWindow.init(allocator, io, &.{ left, right }, 180, 24);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try renderFrame(workbench, &writer.writer);
    const title_y = ui.cell.snap(workbench.part.activeView().?.rect.y);
    const titles = try workbench.frame.prev.rowText(allocator, title_y);
    defer allocator.free(titles);
    try std.testing.expect(std.mem.indexOf(u8, titles, "left") != null);
    try std.testing.expect(std.mem.indexOf(u8, titles, "right") != null);
    _ = try workbench.closeActive();
    try renderFrame(workbench, &writer.writer);
    const remaining = try workbench.frame.prev.rowText(allocator, title_y);
    defer allocator.free(remaining);
    try std.testing.expect(std.mem.indexOf(u8, remaining, "main.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, remaining, "left") == null);
    try std.testing.expect(std.mem.indexOf(u8, remaining, "right") == null);
}

test "Workbench: terminal editor moves the live instance between hosts and closes it once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workbench_window = try TestWindow.init(allocator, io, &.{}, 96, 24);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const service = try TerminalService.init(allocator, io, .{ .launch = launchTestTerminal });
    try workbench.attachTerminalService(service);
    workbench.commands.execute(terminal_ids.new) catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };
    const instance = service.active().?;
    instance.emulator.feed("session state");
    try workbench.commands.execute(terminal_ids.move_to_editor);
    const pane = workbench.activePane().?;
    const tab = pane.activeTab().?;
    try std.testing.expectEqual(instance, tab.terminalInstance().?);
    try std.testing.expectEqual(@as(usize, 0), service.count());
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());
    const keys = try workbench.ensureContextKeys();
    try std.testing.expect(keys.getValue("terminalEditorActive").boolean);
    try std.testing.expectEqual(@as(f64, 1), keys.getValue("terminalCount").number);
    try std.testing.expectEqual(@as(f64, 0), keys.getValue("terminalGroupCount").number);
    try std.testing.expect(workbench.terminalAcceptsPaste());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    const line = try workbench.frame.prev.rowText(allocator, ui.cell.snap(pane.rect.y) + pane.chromeHeight());
    defer allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "session state") != null);

    try workbench.commands.execute(terminal_ids.move_to_panel);
    try std.testing.expectEqual(@as(usize, 0), service.editor.instances.items.len);
    try std.testing.expectEqual(instance, service.active().?);
    try std.testing.expectEqual(@as(usize, 1), workbench.terminalCount());
    try workbench.killTerminal();
    try std.testing.expectEqual(@as(usize, 0), workbench.terminalCount());
}

test "Workbench: sidebar and single editor have outlines with and without cell borders" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "framed.txt", "hello");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 90, 24);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    const caps = ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,outside,radius\x1b\\").?;
    const grid_cells = &workbench.frame.prev;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    for ([_]bool{ false, true }) |native| {
        workbench.setCellBorderCapabilities(if (native) caps else null);
        try workbench.layout.setPartHidden(false, .sidebar);

        try renderFrame(workbench, &out.writer);
        const side = workbench.sidebar_part.base.bounds.?;
        const side_x = ui.cell.snap(side.x);
        const side_right = ui.cell.snap(side.right()) - 1;
        try std.testing.expectEqual(side_right + 1, ui.cell.snap(workbench.part.base.bounds.?.x));
        try std.testing.expectEqual(@as(usize, 1), workbench.groupCount());
        if (native) {
            try std.testing.expectEqual(ui.cell_border.Joint.top_left, grid_cells.borderSetAt(side_x, 0).joints);
            try std.testing.expectEqual(ui.cell_border.Joint.top_right, grid_cells.borderSetAt(side_right, 0).joints);
            try std.testing.expect(std.meta.eql(side, sidebar_part_mod.SidebarPart.innerRect(workbench.sidebar_part.base.bounds.?, workbench.part.cell_borders, workbench.layout.getSideBarPosition())));
        } else {
            try std.testing.expectEqual(@as(u32, '╭'), grid_cells.cluster[grid_cells.index(side_x, 0)]);
            try std.testing.expectEqual(@as(u32, '╮'), grid_cells.cluster[grid_cells.index(side_right, 0)]);
        }

        // The sidebar and editor frames meet at the sash. Either cell should
        // offer the same resize gesture, including with an expanded editor.
        workbench.part.arrangeGroups(.MAXIMIZE);
        for (0..2) |cell| {
            const width = workbench.layout.size(.sidebar);
            const x = ui.cell.snap(workbench.sidebar_part.base.bounds.?.right()) - 1 + cell;
            const border_x = x - cell;
            const background_at = grid_cells.index(border_x, 3);
            terminal_workbench.beginMousePointer(workbench);
            try renderFrame(workbench, &out.writer);
            const idle_background = grid_cells.bg[background_at];
            try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .move, .x = x, .y = 3 }));
            try std.testing.expectEqual(ui.Pointer.ew_resize, workbench.pointerShape());
            try renderFrame(workbench, &out.writer);
            const highlight = ui.cell.packColor(sash_css.hoverStyle(if (workbench.theme_palette) |theme| theme.sashHoverBorder() else null).background.?);
            try std.testing.expectEqual(highlight, grid_cells.bg[background_at]);
            if (native) {
                const stroke = grid_cells.borderSetAt(border_x, 3).strokeAt(ui.cell_border.Segment.right) orelse return error.MissingSashStroke;
                try std.testing.expectEqual(highlight, ui.cell.packColor(stroke.color.rgb));
            }
            terminal_workbench.beginMousePointer(workbench);
            try std.testing.expect(!terminal_workbench.handleSashMouse(workbench, &.{ .kind = .move, .x = x + 4, .y = 3 }));
            try renderFrame(workbench, &out.writer);
            try std.testing.expectEqual(idle_background, grid_cells.bg[background_at]);

            try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .down, .x = x, .y = 3, .button = .left }));
            try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .up, .x = x, .y = 3, .button = .left }));
            try std.testing.expectEqual(width, workbench.layout.size(.sidebar));

            try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .down, .x = x, .y = 3, .button = .left }));
            try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .move, .x = x + 2, .y = 3 }));
            try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .up, .x = x + 2, .y = 3, .button = .left }));
            try std.testing.expectEqual(width + 2, workbench.layout.size(.sidebar));
        }
        workbench.part.restoreGroupSizes();

        try workbench.splitActive(.horizontal);
        const editor_split = workbench.part.root.kind.split;
        const editor_sash_x = ui.cell.snap(editor_split.first.rect.right());
        const sidebar_sash_x = ui.cell.snap(workbench.sidebar_part.base.bounds.?.right()) - 1;
        try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .down, .x = editor_sash_x, .y = 3, .button = .left }));
        terminal_workbench.beginMousePointer(workbench);
        try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .move, .x = sidebar_sash_x, .y = 3 }));
        try std.testing.expect(ui.cell.snap(editor_split.first.rect.right()) < editor_sash_x);
        try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = .up, .x = sidebar_sash_x, .y = 3, .button = .left }));
        try workbench.group_actions.joinAllGroups();

        try workbench.layout.setPartHidden(true, .sidebar);

        try renderFrame(workbench, &out.writer);
        const editor_x = ui.cell.snap(workbench.activity_bar_part.base.bounds.?.w);
        const editor_right = workbench.cols - 1;
        const editor = workbench.activePane().?;
        try std.testing.expectEqual(editor_x, ui.cell.snap(workbench.part.base.bounds.?.x));
        if (native) {
            try std.testing.expectEqual(ui.cell_border.Joint.top_left, grid_cells.borderSetAt(editor_x, 0).joints);
            try std.testing.expectEqual(ui.cell_border.Joint.top_right, grid_cells.borderSetAt(editor_right, 0).joints);
        } else {
            try std.testing.expectEqual(@as(u32, '╭'), grid_cells.cluster[grid_cells.index(editor_x, 0)]);
            try std.testing.expectEqual(@as(u32, '╮'), grid_cells.cluster[grid_cells.index(editor_right, 0)]);
            try std.testing.expectEqual(editor_x + 1, ui.cell.snap(editor.rect.x));
        }
    }
}

test "Workbench: dragging the sash above the bottom panel resizes it" {
    const workbench_window = try TestWindow.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), &.{}, 90, 36);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.showProblems();
    workbench.focusEditor();
    const caps = ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,outside,radius\x1b\\").?;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    for ([_]bool{ false, true }) |native| {
        workbench.setCellBorderCapabilities(if (native) caps else null);
        for (0..2) |inset| {
            try workbench.layout.setSize(.panel, 10);

            try renderFrame(workbench, &output.writer);
            const panel = workbench.panel_part.base.bounds.?;
            const x = ui.cell.snap(panel.x + panel.w / 2);
            const y = ui.cell.snap(panel.y) - inset;
            var event = ui.MouseEvent{ .kind = .move, .x = x, .y = y };
            terminal_workbench.beginMousePointer(workbench);
            try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &event));
            try std.testing.expectEqual(ui.Pointer.ns_resize, workbench.pointer);
            try renderFrame(workbench, &output.writer);
            const grid = &workbench.frame.prev;
            try std.testing.expectEqual(ui.cell.packColor(sash_css.hoverStyle(if (workbench.theme_palette) |theme| theme.sashHoverBorder() else null).background.?), grid.bg[grid.index(x, ui.cell.snap(panel.y))]);

            event.kind = .down;
            event.button = .left;
            try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &event));
            try std.testing.expectEqual(@as(usize, 10), ui.cell.snap(workbench.panel_part.base.bounds.?.h));
            event.kind = .move;
            event.button = .none;
            event.y -= 3;
            try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &event));
            try std.testing.expectEqual(@as(usize, 13), ui.cell.snap(workbench.panel_part.base.bounds.?.h));
            event.kind = .up;
            event.y += 5;
            try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &event));
            try std.testing.expectEqual(@as(usize, 8), ui.cell.snap(workbench.panel_part.base.bounds.?.h));
            try std.testing.expectEqual(Focus.editor, workbench.focus);
        }
    }

    const title = workbench.geometry().panelRect();
    const x = ui.cell.snap(title.x) + 2;
    const y = ui.cell.snap(title.y);
    try std.testing.expect(panel_part_mod.hitTest(&workbench.panel_part, title, x, y) != null);
    const title_press = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(!terminal_workbench.handleSashMouse(workbench, &title_press));
    try std.testing.expect(terminal_workbench.handlePanelMouse(workbench, &title_press));

    const panel = workbench.panel_part.base.bounds.?;
    const divider_x = ui.cell.snap(panel.x + panel.w / 2);
    var drag = ui.MouseEvent{ .kind = .down, .x = divider_x, .y = ui.cell.snap(panel.y), .button = .left };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &drag));
    const wheel = ui.MouseEvent{ .kind = .wheel, .x = drag.x, .y = drag.y, .delta_y = 3 };
    try std.testing.expect(!terminal_workbench.handleSashMouse(workbench, &wheel));
    drag.kind = .move;
    drag.y = 0;
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &drag));
    try std.testing.expectEqual(editor_part.min_pane_height, ui.cell.snap(workbench.part.base.bounds.?.h));
    try std.testing.expectEqual(workbench.layout.workbenchRows(workbench.rows) - editor_part.min_pane_height, ui.cell.snap(workbench.panel_part.base.bounds.?.h));
    drag.y = workbench.layout.workbenchRows(workbench.rows);
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &drag));
    try std.testing.expectEqual(workbench.panel_part.minimum_height, ui.cell.snap(workbench.panel_part.base.bounds.?.h));
    try std.testing.expect(workbench.cancelSashDrag());
    try std.testing.expect(workbench.layout.workbench_grid.activeSash() == null);
}

test "Workbench: right sidebar moves its rail, hit targets and snapping sash together" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "right.txt", "right sidebar");
    defer allocator.free(path);
    const settings = try seedFile(allocator, io, &tmp, "settings.json", "{}");
    defer allocator.free(settings);
    const window = try TestWindow.init(allocator, io, &.{path}, 90, 12);
    defer window.deinit();
    const wb = window.workbench;
    try wb.setUserSettingsPaths(&.{settings});
    try wb.initSidebar(std.fs.path.dirname(path).?);
    pumpSidebarForTests(wb);
    try wb.setUserConfigurationValue("workbench.sideBar.location", .{ .string = "right" });
    const rects = wb.geometry().workbenchGridLayout();
    try std.testing.expectEqual(workbench_layout.Position.right, wb.layout_api.getSideBarPosition());
    try std.testing.expectEqual(@as(f64, 0), rects.editor.x);
    try std.testing.expectEqual(rects.editor.right(), rects.sidebar.x);
    try std.testing.expectEqual(rects.sidebar.right(), rects.activity_bar.x);
    try std.testing.expectEqual(@as(f64, 90), rects.activity_bar.right());
    try std.testing.expectEqual(rects.sidebar, wb.sidebar_part.base.bounds.?);
    try std.testing.expect(!terminal_workbench.handleSidebarMouse(wb, &.{ .x = 1, .y = 2, .kind = .move }));
    try std.testing.expect(terminal_workbench.handleSidebarMouse(wb, &.{ .x = 89, .y = 1, .kind = .move }));
    var frame = std.Io.Writer.Allocating.init(allocator);
    defer frame.deinit();
    try renderFrame(wb, &frame.writer);
    const edge = ui.cell.snap(rects.sidebar.x);
    const initial = wb.layout.size(.sidebar);
    try sidebarMouseForTest(wb, .down, edge);
    try sidebarMouseForTest(wb, .move, edge - 4);
    try std.testing.expectEqual(initial + 4, wb.layout.size(.sidebar));
    try sidebarMouseForTest(wb, .up, edge - 4);
    const minimum = wb.sidebar_part.minimum_width + 1;
    const collapse = edge + ui.cell.snap(rects.sidebar.w) - minimum + minimum / 2;
    try sidebarMouseForTest(wb, .down, edge - 4);
    try sidebarMouseForTest(wb, .move, collapse - 1);
    try std.testing.expect(wb.layout.isVisible(.sidebar));
    try sidebarMouseForTest(wb, .move, collapse);
    try std.testing.expect(!wb.layout.isVisible(.sidebar));
    try std.testing.expectEqual(ui.Pointer.w_resize, wb.pointerShape());
    try sidebarMouseForTest(wb, .up, collapse);
    const hidden_edge = ui.cell.snap(wb.geometry().workbenchGridLayout().activity_bar.x) - 1;
    try sidebarMouseForTest(wb, .down, hidden_edge);
    try sidebarMouseForTest(wb, .move, hidden_edge - minimum);
    try std.testing.expect(wb.layout.isVisible(.sidebar));
    try sidebarMouseForTest(wb, .up, hidden_edge - minimum);
    const alt_edge = wb.geometry().workbenchGridLayout().sidebarSashCell();
    try std.testing.expect(terminal_workbench.handleSashMouse(wb, &.{ .kind = .down, .x = alt_edge, .y = 2, .button = .left, .mods = .{ .alt = true } }));
    try std.testing.expect(terminal_workbench.handleSashMouse(wb, &.{ .kind = .move, .x = 89, .y = 2, .mods = .{ .alt = true } }));
    try std.testing.expect(wb.layout.isVisible(.sidebar));
    try sidebarMouseForTest(wb, .up, 89);
    try wb.setUserConfigurationValue("workbench.sideBar.location", .{ .string = "left" });
    try std.testing.expectEqual(@as(f64, 0), wb.geometry().workbenchGridLayout().activity_bar.x);
}

test "Workbench: dragging the sidebar divider resizes the side bar" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const filename = "a_long_filename_for_the_resize_test.txt";
    const path = try seedFile(allocator, io, &tmp, filename, "alpha");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 70, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);

    const before = workbench.layout.size(.sidebar);
    const divider = ui.cell.snap(workbench.activity_bar_part.base.bounds.?.w) + before;
    try std.testing.expect(workbench.layout.isVisible(.sidebar));

    const down = ui.MouseEvent{ .kind = .down, .x = divider, .y = 2, .button = .left };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &down));
    try std.testing.expectEqual(WorkbenchGrid.Sash.sidebar, workbench.layout.workbench_grid.activeSash().?);

    const move = ui.MouseEvent{ .kind = .move, .x = divider + 4, .y = 2, .button = .left };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &move));
    try std.testing.expectEqual(before + 4, workbench.layout.size(.sidebar));

    const up = ui.MouseEvent{ .kind = .up, .x = divider + 4, .y = 2, .button = .left };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &up));
    try std.testing.expect(workbench.layout.workbench_grid.activeSash() == null);

    // The editor minimum, not a fraction of the window, stops the sash.
    const far = ui.MouseEvent{ .kind = .down, .x = ui.cell.snap(workbench.activity_bar_part.base.bounds.?.w) + workbench.layout.size(.sidebar), .y = 2, .button = .left };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &far));
    const drag_far = ui.MouseEvent{ .kind = .move, .x = 10_000, .y = 2, .button = .left };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &drag_far));
    try std.testing.expect(workbench.layout.size(.sidebar) > workbench.cols / 2);
    try std.testing.expectEqual(editor_part.min_pane_width, ui.cell.snap(workbench.part.base.bounds.?.w));

    try std.testing.expectEqual(ui.Pointer.w_resize, workbench.pointerShape());
    try sidebarMouseForTest(workbench, .up, drag_far.x);
    const maximum = workbench.layout.size(.sidebar);
    const rail = ui.cell.snap(workbench.activity_bar_part.base.bounds.?.w);
    const minimum = workbench.sidebar_part.minimum_width + @as(usize, @intFromBool(!workbench.part.cell_borders));
    const half = minimum / 2;
    const start = rail + maximum;
    const threshold = start - ui.cell.snap(workbench.sidebar_part.base.bounds.?.w) + minimum - half;
    workbench.focusSidebar();
    try sidebarMouseForTest(workbench, .down, start);
    try sidebarMouseForTest(workbench, .move, threshold);
    try std.testing.expectEqual(workbench.sidebar_part.minimum_width, workbench.layout.size(.sidebar));
    try std.testing.expectEqual(ui.Pointer.e_resize, workbench.pointerShape());
    try sidebarMouseForTest(workbench, .move, threshold - 1);
    try std.testing.expect(!workbench.layout.isVisible(.sidebar));
    try std.testing.expectEqual(Focus.editor, workbench.focus);
    try std.testing.expectEqual(rail, ui.cell.snap(workbench.part.base.bounds.?.x));

    // The same captured press can cross the threshold in either direction.
    try sidebarMouseForTest(workbench, .move, threshold);
    try std.testing.expect(workbench.layout.isVisible(.sidebar));
    try std.testing.expectEqual(workbench.sidebar_part.minimum_width, workbench.layout.size(.sidebar));
    try sidebarMouseForTest(workbench, .up, threshold - 1);
    try std.testing.expect(!workbench.sidebar_part.isVisible());
    try workbench.toggleSidebar();
    try std.testing.expectEqual(maximum, workbench.layout.size(.sidebar));
    try workbench.toggleSidebar();

    // A fresh press on the hidden sash snaps open at half the minimum.
    try sidebarMouseForTest(workbench, .down, rail);
    try sidebarMouseForTest(workbench, .move, rail + half - 1);
    try std.testing.expect(!workbench.layout.isVisible(.sidebar));
    try sidebarMouseForTest(workbench, .move, rail + half);
    try std.testing.expect(workbench.layout.isVisible(.sidebar));
    try std.testing.expectEqual(workbench.sidebar_part.minimum_width, workbench.layout.size(.sidebar));
    try sidebarMouseForTest(workbench, .up, rail + minimum + 4);
    try std.testing.expectEqual(minimum + 4, ui.cell.snap(workbench.sidebar_part.base.bounds.?.w));

    // Double-click measures the full label even while its paint is clipped.
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try renderFrame(workbench, &output.writer);
    const click_x = ui.cell.snap(workbench.sidebar_part.base.bounds.?.right()) - 1;
    for (0..2) |_| {
        try sidebarMouseForTest(workbench, .down, click_x);
        try sidebarMouseForTest(workbench, .up, click_x);
    }
    try std.testing.expectEqual(6 + filename.len + 1, workbench.layout.size(.sidebar));

    // Alt-drag keeps the sidebar visible and applies the last-sash half bound.
    const alt_start = workbench.layout.size(.sidebar);
    const alt_edge = ui.cell.snap(workbench.sidebar_part.base.bounds.?.right()) - 1;
    for ([_]ui.MouseKind{ .down, .move, .up }) |kind| {
        try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{
            .kind = kind,
            .x = if (kind == .down) alt_edge else 0,
            .y = 2,
            .button = .left,
            .mods = .{ .alt = true },
        }));
    }
    try std.testing.expectEqual(alt_start - (alt_start - workbench.sidebar_part.minimum_width) / 2, workbench.layout.size(.sidebar));

    try workbench.showProblems();
    try workbench.layout.resizeEditorPart(-100, 0);
    try std.testing.expectEqual(@as(usize, 18), ui.cell.snap(workbench.panel_part.base.bounds.?.w));
    try workbench.commands.execute("workbench.action.closePanel");

    // An uneven editor split must still reserve each group's minimum.
    try workbench.splitActive(.horizontal);
    workbench.part.root.kind.split.ratio = 0.8;
    try workbench.layout.resizeEditorPart(-100, 0);
    const split = workbench.part.root.kind.split;
    try std.testing.expectEqual(editor_part.min_pane_width, ui.cell.snap(split.first.rect.w));
    try std.testing.expectEqual(editor_part.min_pane_width, ui.cell.snap(split.second.rect.w));
    try workbench.resize(50, 12);
    try std.testing.expectEqual(editor_part.min_pane_width, ui.cell.snap(split.first.rect.w));
    try std.testing.expectEqual(editor_part.min_pane_width, ui.cell.snap(split.second.rect.w));
    workbench.part.arrangeGroups(.MAXIMIZE);
    try workbench.layout.resizeEditorPart(-100, 0);
    try std.testing.expectEqual(editor_part.min_pane_width, ui.cell.snap(workbench.part.base.bounds.?.w));
}

test "Workbench: zen mode hides chrome, line numbers and tabs and restores them" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "zen.txt", "alpha\nbeta\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var settings_file = try tmp.dir.createFile(io, "zen-settings.json", .{});
    try settings_file.writeStreamingAll(io, "{}");
    settings_file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/zen-settings.json", .{buffer[0..root_len]});
    defer allocator.free(settings_path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 80, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    _ = try workbench.showActivityById("explorer");
    _ = try workbench.panel_part.pane.openPaneComposite(PROBLEMS_CONTAINER_ID, false);
    try workbench.panel_part.setVisible(true);

    const pane = workbench.activePane().?;
    const tab = workbench.activeTab().?;
    try std.testing.expect(workbench.layout.isVisible(.sidebar));
    try std.testing.expect(workbench.geometry().panelShown());
    try std.testing.expect(workbench.activity_bar_part.visible);
    try std.testing.expect(workbench.geometry().statusBarVisible());
    try std.testing.expectEqual(editor_options.RenderLineNumbersType.On, tab.view.terminal_view_host.options.get(.lineNumbers).render_type);
    try std.testing.expectEqual(layout_service_mod.EditorTabsMode.multiple, workbench.part.part_options.show_tabs);
    try std.testing.expect(!workbench.layout.isMainEditorCentered());

    var zen_events: usize = 0;
    try workbench.layout.on_did_change_zen_mode.event(&zen_events, struct {
        fn callback(_: bool, context: *usize) !void {
            context.* += 1;
        }
    }.callback);

    try workbench.commands.execute(zen_mode_contribution.toggle_zen_mode_id);
    try std.testing.expect(workbench.layout.isZenModeActive());
    try std.testing.expectEqual(@as(usize, 1), zen_events);
    try std.testing.expect(!workbench.layout.isVisible(.sidebar));
    try std.testing.expect(!workbench.geometry().panelShown());
    try std.testing.expect(!workbench.activity_bar_part.visible);
    try std.testing.expect(!workbench.geometry().statusBarVisible());
    try std.testing.expectEqual(editor_options.RenderLineNumbersType.Off, tab.view.terminal_view_host.options.get(.lineNumbers).render_type);
    // The default `zenMode.centerLayout` centers the single editor group.
    try std.testing.expect(workbench.layout.isMainEditorCentered());
    try std.testing.expect(workbench.layout.isMainEditorCenteredEffective());
    try std.testing.expect(workbench.part.viewport.w < workbench.part.base.bounds.?.w);
    try std.testing.expectEqual(Focus.editor, workbench.focus);
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try renderFrame(workbench, &rendered.writer);

    // The zen tab actions write `zenMode.showTabs` and take effect while zen
    // mode is active, without touching `workbench.editor.showTabs`.
    try workbench.commands.execute(zen_mode_contribution.zen_hide_editor_tabs_id);
    try std.testing.expectEqual(layout_service_mod.EditorTabsMode.none, workbench.part.part_options.show_tabs);
    try std.testing.expect(!pane.tabs_visible);
    try workbench.commands.execute(zen_mode_contribution.zen_show_single_editor_tab_id);
    try std.testing.expectEqual(layout_service_mod.EditorTabsMode.single, workbench.part.part_options.show_tabs);
    try workbench.commands.execute(zen_mode_contribution.zen_show_multiple_editor_tabs_id);
    try std.testing.expectEqual(layout_service_mod.EditorTabsMode.multiple, workbench.part.part_options.show_tabs);

    try workbench.commands.execute(zen_mode_contribution.exit_zen_mode_id);
    try std.testing.expect(!workbench.layout.isZenModeActive());
    try std.testing.expectEqual(@as(usize, 2), zen_events);
    try std.testing.expect(workbench.layout.isVisible(.sidebar));
    try std.testing.expect(workbench.geometry().panelShown());
    try std.testing.expect(workbench.activity_bar_part.visible);
    try std.testing.expect(workbench.geometry().statusBarVisible());
    try std.testing.expectEqual(editor_options.RenderLineNumbersType.On, tab.view.terminal_view_host.options.get(.lineNumbers).render_type);
    try std.testing.expectEqual(layout_service_mod.EditorTabsMode.multiple, workbench.part.part_options.show_tabs);
    try std.testing.expect(!workbench.layout.isMainEditorCentered());
    try std.testing.expectEqual(Focus.editor, workbench.focus);
}

test "Workbench: side bar part paints the title and runs its actions" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "title_action.txt", "alpha beta\n");
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 70, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    // The title row belongs to the side bar part and the label is uppercased.
    const explorer_title = try workbench.frame.present().rowText(allocator, 0);
    defer allocator.free(explorer_title);
    try std.testing.expect(std.mem.indexOf(u8, explorer_title, "EXPLORER") != null);
    // The Explorer view has no header of its own: its first tree row follows
    // the title directly.
    const first_tree_row = try workbench.frame.present().rowText(allocator, 1);
    defer allocator.free(first_tree_row);
    try std.testing.expect(std.mem.indexOf(u8, first_tree_row, "title_action.txt") != null);

    // The title row, the content and the divider column share the side bar
    // background; only the divider glyph gets the border foreground.
    const side_bar_bg = ui.cell.packColor(ui.Color{ .r = 30, .g = 30, .b = 33 });
    const presented = workbench.frame.present();
    const title_right = ui.cell.snap(workbench.activity_bar_part.base.bounds.?.w) + workbench.layout.size(.sidebar) - 1;
    try std.testing.expectEqual(side_bar_bg, presented.bg[presented.index(title_right, 0)]);
    const divider = ui.cell.snap(workbench.activity_bar_part.base.bounds.?.w) + workbench.layout.size(.sidebar);
    try std.testing.expectEqual(side_bar_bg, presented.bg[presented.index(divider, 0)]);
    try std.testing.expectEqual(side_bar_bg, presented.bg[presented.index(divider, 5)]);
    try std.testing.expectEqual(
        ui.cell.packColor(ui.Color{ .r = 70, .g = 70, .b = 70 }),
        presented.fg[presented.index(divider, 5)],
    );

    try workbench.findInFiles();
    const view = workbench.search_window.view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    try waitForSearch(workbench);
    try std.testing.expect(view.rows.items.len > 0);
    const details_before = view.widget.details_visible;

    out.clearRetainingCapacity();
    try renderFrame(workbench, &out.writer);
    const search_title = try workbench.frame.present().rowText(allocator, 0);
    defer allocator.free(search_title);
    try std.testing.expect(std.mem.indexOf(u8, search_title, "SEARCH") != null);

    // Find the title action through the same hit testing as a mouse press.
    const sidebar_rect = sidebar_part_mod.SidebarPart.innerRect(workbench.sidebar_part.base.bounds.?, workbench.part.cell_borders, workbench.layout.getSideBarPosition());
    const title_y = ui.cell.snap(sidebar_rect.y);
    var clear_x: ?usize = null;
    for (ui.cell.snap(sidebar_rect.x)..ui.cell.snap(sidebar_rect.right())) |x| {
        if (sidebar_part_mod.hitTest(&workbench.sidebar_part, sidebar_rect, x, title_y)) |hit| {
            if (hit == .action and std.mem.eql(u8, hit.action, search_command_ids.clear_search_results)) {
                clear_x = x;
                break;
            }
        }
    }
    const clear_click = ui.MouseEvent{ .kind = .down, .button = .left, .x = clear_x.?, .y = title_y };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &clear_click));
    try std.testing.expectEqual(@as(usize, 0), view.rows.items.len);

    const details = view.widget.controlRect(.more).?;
    const details_click = ui.MouseEvent{
        .kind = .down,
        .button = .left,
        .x = ui.cell.snap(view.last_rect.x + details.x),
        .y = ui.cell.snap(view.last_rect.y + details.y),
    };
    try std.testing.expect(details_click.y > title_y);
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &details_click));
    try std.testing.expectEqual(!details_before, view.widget.details_visible);
    try std.testing.expectEqual(search_widget_mod.Field.includes, view.widget.focus_field);
}

test "Workbench: search guides, preview ellipses and the Open in editor link" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "prefix words before a significant amount of extra context alpha and more trailing words after the match alpha";
    const path = try seedFile(allocator, io, &tmp, "preview.txt", source);
    defer allocator.free(path);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 100, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    try workbench.layout.setSize(.sidebar, 45);
    pumpSidebarForTests(workbench);
    try workbench.findInFiles();
    const view = workbench.search_window.view.?;
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    try waitForSearch(workbench);
    try std.testing.expectEqual(@as(usize, 2), view.matchCount());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    const x = ui.cell.snap(view.last_rect.x);
    const y = ui.cell.snap(view.last_rect.y) + view.results_y + 1;
    const end = ui.cell.snap(view.last_rect.right());
    const grid = workbench.frame.present();
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(x, y)]);
    const snippet = try grid.rowText(allocator, y);
    defer allocator.free(snippet);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, snippet, "…"));
    try std.testing.expect(std.mem.indexOf(u8, snippet, "alpha") != null);

    const move = ui.MouseEvent{ .kind = .move, .x = x + 4, .y = y };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &move));
    try renderFrame(workbench, &out.writer);
    const hovered = workbench.frame.present();
    try std.testing.expectEqual(@as(u32, '│'), hovered.cluster[hovered.index(x, y)]);
    try std.testing.expect(hovered.cluster[hovered.index(end - 2, y)] != '│');

    const link = view.open_in_editor_rect;
    try std.testing.expectEqual(@as(f64, "Open in editor".len), link.w);
    const link_x = ui.cell.snap(link.x);
    const link_y = ui.cell.snap(link.y);
    const status = try hovered.rowText(allocator, link_y);
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "2 results in 1 file - Open in editor") != null);
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &.{ .kind = .move, .x = link_x, .y = link_y }));
    try std.testing.expectEqual(ui.Pointer.pointer, workbench.pointer);
    try renderFrame(workbench, &out.writer);
    const after_hover = workbench.frame.present();
    try std.testing.expectEqual(@as(u32, ' '), after_hover.cluster[after_hover.index(x, y)]);

    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &.{ .kind = .down, .button = .left, .x = link_x, .y = link_y }));
    const snapshot = workbench.activeTab().?;
    try std.testing.expectEqualStrings("Search: alpha", snapshot.input.getName());
    try std.testing.expect(snapshot.editor.read_only);
    var contents = try snapshot.editor.model.getValue(null, false);
    defer contents.deinit();
    const expected = try std.fmt.allocPrint(allocator, "2 results - 1 file\n\npreview.txt:\n  1: {s}\n", .{source});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, contents.items);
    const decorations = try snapshot.editor.model.getAllDecorations(0, false);
    defer allocator.free(decorations);
    var match_line = try snapshot.editor.model.getLineContent(4);
    defer match_line.deinit();
    var matches: usize = 0;
    for (decorations) |decoration| {
        if (decoration.range.startLineNumber == 4 and
            decoration.range.endColumn - decoration.range.startColumn == "alpha".len)
        {
            const range = decoration.range;
            try std.testing.expectEqualStrings("alpha", match_line.items[range.startColumn - 1 .. range.endColumn - 1]);
            matches += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), matches);
}

test "Workbench: search aligns nested guides and keeps the link inline at the result limit" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "nested/results.txt", "alpha one\nalpha two\nalpha three\n");
    defer allocator.free(path);
    const settings = try seedFile(allocator, io, &tmp, "settings.json",
        \\{"search.maxResults":2,"workbench.activityBar.location":"top"}
    );
    defer allocator.free(settings);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 100, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.setUserSettingsPaths(&.{settings});
    try workbench.initSidebar(root);
    try workbench.layout.setSize(.sidebar, 45);
    pumpSidebarForTests(workbench);
    const caps = ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,half,center,round,outside,radius\x1b\\").?;
    workbench.setCellBorderCapabilities(caps);
    try workbench.findInFiles();
    const view = workbench.search_window.view.?;
    view.commandViewAsTree(true);
    try view.widget.setValue(.search, "alpha");
    try view.startSearch();
    try waitForSearch(workbench);
    try std.testing.expect(view.model.limitHit());
    try std.testing.expectEqual(@as(usize, 2), view.matchCount());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    const x = ui.cell.snap(view.last_rect.x);
    const y = ui.cell.snap(view.last_rect.y) + view.results_y;
    const grid = workbench.frame.present();
    const status = try grid.rowText(allocator, y - 1);
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "2 results in 1 file - Open in editor") != null);

    // The file is the folder's child, and the match is the file's child.
    const folder_col = x;
    const file_col = x + 2;
    try std.testing.expectEqual(@as(u32, '⌄'), grid.cluster[grid.index(folder_col, y)]);
    try std.testing.expectEqual(@as(u32, '⌄'), grid.cluster[grid.index(file_col, y + 1)]);
    const move = ui.MouseEvent{ .kind = .move, .x = x + 5, .y = y + 2 };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &move));
    try renderFrame(workbench, &out.writer);
    const hovered = workbench.frame.present();
    try std.testing.expect(hovered.borderSetAt(folder_col, y + 1).strokeAt(ui.cell_border.Segment.v_top) != null);
    try std.testing.expect(hovered.borderSetAt(folder_col, y + 2).strokeAt(ui.cell_border.Segment.v_top) != null);
    try std.testing.expect(hovered.borderSetAt(file_col, y + 2).strokeAt(ui.cell_border.Segment.v_top) != null);
    try std.testing.expect(hovered.borderSetAt(file_col + 1, y + 2).strokeAt(ui.cell_border.Segment.v_top) == null);
}

test "Workbench: outline side panel shows provider symbols" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try seedFile(allocator, io, &tmp, "outline/file.ts", "class A {}\nfunction b() {}\n");
    defer allocator.free(path);

    const Fake = struct {
        var labels = [_][]const u8{ "A", "b" };
        var nodes: [2]u8 = undefined;
        var elements: [2]outline_mod.TreeElement = undefined;
        var roots: [1]outline_mod.TreeElement = undefined;
        var outline: outline_mod.IOutline = undefined;
        var revealed: usize = 0;

        fn matches(_: *anyopaque, _: OutlineEditor) bool {
            return true;
        }
        fn create(_: *anyopaque, _: OutlineEditor, target: outline_mod.OutlineTarget) !?*outline_mod.IOutline {
            _ = target;
            return &outline;
        }
        fn rootsFor(_: *anyopaque) []const outline_mod.TreeElement {
            return roots[0..];
        }
        fn breadcrumbs(_: *anyopaque) []const outline_mod.BreadcrumbsOutlineElement {
            return &.{};
        }
        fn reveal(_: *anyopaque, _: *anyopaque, _: outline_mod.RevealOptions) !void {
            revealed += 1;
        }
        fn dispose(_: *anyopaque) void {}
    };
    var context: u8 = 0;
    Fake.nodes = .{ 1, 2 };
    Fake.elements[0] = .{
        .element = @ptrCast(&Fake.nodes[0]),
        .label = Fake.labels[0],
        .symbol_kind = 5,
        .id = "a",
    };
    Fake.elements[1] = .{
        .element = @ptrCast(&Fake.nodes[1]),
        .label = Fake.labels[1],
        .symbol_kind = 12,
        .id = "b",
    };
    Fake.roots[0] = .{
        .element = @ptrCast(&Fake.nodes[0]),
        .label = Fake.labels[0],
        .symbol_kind = 5,
        .id = "a",
        .collapsible = true,
        .children = Fake.elements[1..2],
    };
    Fake.outline = .{
        .context = @ptrCast(&context),
        .uri = path,
        .outline_kind = "test",
        .config = .{
            .breadcrumbs_data_source = .{ .context = @ptrCast(&context), .get_breadcrumb_elements = Fake.breadcrumbs },
            .tree_data_source = .{ .context = @ptrCast(&context), .get_roots = Fake.rootsFor },
        },
        .revealFn = Fake.reveal,
        .disposeFn = Fake.dispose,
    };

    const workbench_window = try TestWindow.init(allocator, io, &.{}, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const registration = try workbench.outline_service.registerOutlineCreator(.{
        .context = @ptrCast(&context),
        .matches = Fake.matches,
        .create_outline = Fake.create,
    });
    defer registration.dispose();
    try workbench.openPath(path);
    try workbench.activeTab().?.ensureControllers();
    _ = try workbench.showActivityById("explorer");
    try std.testing.expect(workbench.explorer_container.?.model.isCollapsed("outline"));
    workbench.explorer_container.?.model.setCollapsed("outline", false);
    workbench.explorer_container.?.setActive("outline");
    try workbench.commands.execute("outline.focus");

    const view = workbench.outline_view.?;
    try std.testing.expectEqual(@as(usize, 2), view.rowCount());
    try std.testing.expectEqualStrings("A", view.rowLabel(0).?);
    try std.testing.expectEqualStrings("b", view.rowLabel(1).?);
    try std.testing.expectEqual(@as(usize, 2), view.rowDepth(1).?);

    view.setFocused(true);
    view.selectRow(1);
    try std.testing.expect(try view.handleKey(&.{ .key = .enter }));
    try std.testing.expectEqual(@as(usize, 1), Fake.revealed);

    try view.setFollowCursor(true);
    const actions = view.titleActions();
    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqualStrings("outline.collapse", actions[0].id);
    try std.testing.expectEqual(@as(u21, 0xeac5), actions[0].glyph);
    try std.testing.expectEqualStrings(OutlinePane.more_actions_id, actions[1].id);
    try workbench.commands.execute(OutlinePane.more_actions_id);
    try std.testing.expect(!workbench.isQuickAccessOpen());
    const popup = workbench.context_menu_service.current.?.popup.?;
    try std.testing.expect(popup.items[0].checked);
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .home }));
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .enter }));
    try std.testing.expect(!view.view_state.follow_cursor);
    try std.testing.expect(workbench.context_menu_service.current == null);

    try workbench.commands.execute("outline.collapse");
    try std.testing.expectEqual(@as(usize, 1), view.rowCount());
    try std.testing.expectEqualStrings("outline.expand", view.titleActions()[0].id);
    try workbench.commands.execute("outline.expand");
    try std.testing.expectEqual(@as(usize, 2), view.rowCount());
    try workbench.commands.execute("outline.filterOnType");
    try std.testing.expect(!view.view_state.filter_on_type);
    try workbench.commands.execute("outline.filterOnType");
    try std.testing.expect(view.view_state.filter_on_type);
    try workbench.commands.execute("outline.sortByName");
    try std.testing.expectEqual(.ByName, view.view_state.sort_by);
    try workbench.commands.execute("outline.sortByKind");
    try std.testing.expectEqual(.ByKind, view.view_state.sort_by);
    try workbench.commands.execute("outline.sortByPosition");
    try std.testing.expectEqual(.ByPosition, view.view_state.sort_by);

    // The native title menu also resolves contributions registered after startup.
    const Probe = struct {
        workbench: *Workbench,
        calls: std.ArrayList(u8) = .empty,
        fn show(_: void, probe: *@This()) !void {
            try probe.calls.append(std.testing.allocator, 's');
        }
        fn hide(_: void, probe: *@This()) !void {
            try probe.calls.append(std.testing.allocator, 'h');
        }
        fn run(ptr: *anyopaque) anyerror!void {
            const probe: *@This() = @ptrCast(@alignCast(ptr));
            try std.testing.expect(probe.workbench.context_menu_service.current == null);
            try probe.calls.append(std.testing.allocator, 'r');
            try probe.workbench.commands.execute(OutlinePane.more_actions_id);
        }
    };
    var probe = Probe{ .workbench = workbench };
    defer probe.calls.deinit(allocator);
    const menus = &workbench.context_menu_service;
    const show_listener = try menus.on_did_show_context_menu.listen(&probe, Probe.show);
    defer menus.on_did_show_context_menu.unlisten(show_listener);
    const hide_listener = try menus.on_did_hide_context_menu.listen(&probe, Probe.hide);
    defer menus.on_did_hide_context_menu.unlisten(hide_listener);
    const title = @import("../vs/platform/actions/common/actions.zig").menu_ids.ViewTitle;
    try workbench.commands.platform.register(.{ .id = "test.outline", .context = &probe, .run = Probe.run });
    try workbench.commands.menus.appendMenuGroup(title, "zz_test", "More");
    try workbench.commands.menus.appendMenuItem(title, .{ .command = .{ .id = "test.outline", .title = "$(symbol-method) Run Contribution" }, .group = "zz_test", .when = &.{ .Equals = .{ .key = "view", .value = .{ .string = "outline" } } } });
    try workbench.commands.menus.appendMenuItem(title, .{ .command = .{ .id = "test.hidden", .title = "Another View" }, .group = "zz_test", .when = &.{ .Equals = .{ .key = "view", .value = .{ .string = "elsewhere" } } } });
    try workbench.commands.execute(OutlinePane.more_actions_id);
    const rows = menus.current.?.popup.?.items;
    try std.testing.expectEqualStrings("More", rows[rows.len - 2].label);
    try std.testing.expect(!rows[rows.len - 2].enabled);
    try std.testing.expect(menus.handleKey(&.{ .key = .end }));
    try std.testing.expectEqualStrings("Run Contribution", menus.current.?.popup.?.focusedItem().?.label);
    try std.testing.expect(menus.handleKey(&.{ .key = .enter }));
    try std.testing.expectEqualStrings("shrs", probe.calls.items);
    try std.testing.expect(menus.handleKey(&.{ .key = .escape }));
    try std.testing.expectEqualStrings("shrsh", probe.calls.items);
}

test "Workbench: closing the active tab detaches the outline editor handler" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try seedFile(allocator, io, &tmp, "outline-a.txt", "alpha");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "outline-b.txt", "beta");
    defer allocator.free(path_b);

    const workbench_window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 60, 12);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    _ = try workbench.showActivityById("explorer");
    workbench.explorer_container.?.model.setCollapsed("outline", false);
    try workbench.commands.execute("outline.focus");

    const view = workbench.outline_view.?;
    const old_editor = workbench.activeTab().?.editor;
    try std.testing.expect(view.editor == old_editor);

    _ = try workbench.closeActive();
    try std.testing.expect(workbench.activeTab() != null);
    // The old editor is detached and the replacement active pane is bound
    // synchronously through the editor service, before any render/input.
    try std.testing.expect(view.editor != old_editor);
    try std.testing.expectEqual(workbench.activeTab().?.editor, view.editor.?);
    workbench.explorer_container.?.model.setCollapsed("outline", true);
    try std.testing.expect(!view.body_visible);
    try std.testing.expect(view.editor == null);
    try workbench.openPath(path_a);
    try std.testing.expect(view.editor == null);
    workbench.explorer_container.?.model.setCollapsed("outline", false);
    try std.testing.expect(view.body_visible);
    try std.testing.expectEqual(workbench.activeTab().?.editor, view.editor.?);
    try workbench.layout.setPartHidden(true, .sidebar);
    try std.testing.expect(!view.body_visible and view.editor == null);
    try workbench.layout.setPartHidden(false, .sidebar);
    try std.testing.expect(view.body_visible);
    try std.testing.expectEqual(workbench.activeTab().?.editor, view.editor.?);
}

test "Workbench: git scm integration stages selected inner changes through the diff gutter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    if (!try runGitTest(allocator, root, &.{"init"})) return error.SkipZigTest;
    _ = try runGitTest(allocator, root, &.{ "config", "core.autocrlf", "false" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.name", "Test User" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.email", "test@example.com" });
    const original = "alpha\nabc old def stale\nunchanged1\nunchanged2\nunchanged3\nlast old\n";
    const modified = "alpha\nabc new def fresh\nunchanged1\nunchanged2\nunchanged3\nlast NEW\n";
    const partial = "alpha\nabc new def stale\nunchanged1\nunchanged2\nunchanged3\nlast old\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = original });
    if (!try runGitTest(allocator, root, &.{ "add", "a.txt" })) return error.SkipZigTest;
    if (!try runGitTest(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "initial" })) return error.SkipZigTest;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = modified });
    const path = try std.fs.path.join(allocator, &.{ root, "a.txt" });
    defer allocator.free(path);
    const window = try TestWindow.init(allocator, io, &.{path}, 100, 24);
    defer window.deinit();
    const workbench = window.workbench;
    const settings = try std.fs.path.join(allocator, &.{ root, ".git", "test-settings.json" });
    defer allocator.free(settings);
    try workbench.setUserSettingsPaths(&.{settings});
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.initGit();
    const provider = workbench.git_model.repository.?;
    const resource = provider.groups[2].resources.items[0];
    try workbench.scm.changes.?.host.open_change(workbench.scm.changes.?.host.context, &resource.iface);
    try pumpDiffForTests(workbench);
    const tab = workbench.activeTab().?;
    const widget = tab.diff.?.widget;
    try std.testing.expect(widget.gutter_toolbar.hasActions());
    try std.testing.expect(widget.paneWidths().toolbar > 0);
    try std.testing.expect(std.mem.endsWith(u8, widget.gutter_toolbar.original_uri, "%22ref%22%3A%22~%22%7D"));
    try workbench.setUserConfigurationValue("diffEditor.renderGutterMenu", .{ .bool = false });
    try std.testing.expectEqual(@as(usize, 0), widget.paneWidths().toolbar);
    try workbench.setUserConfigurationValue("diffEditor.renderGutterMenu", .{ .bool = true });
    try std.testing.expect(widget.paneWidths().toolbar > 0);
    const selected = @import("../vs/editor/common/core/range.zig").Range.init(2, 5, 2, 8);
    try widget.modified_editor.setSelection(selected);
    try std.testing.expect(widget.gutter_toolbar.selected_mapping != null);
    var frame: std.Io.Writer.Allocating = .init(allocator);
    defer frame.deinit();
    try renderFrame(workbench, &frame.writer);
    const col = widget.paneWidths().toolbarLeft(widget.sideBySide());
    const row = for (0..widget.height) |row| {
        if (try widget.pointerAt(col, row) == .pointer) break row;
    } else return error.TestExpectedDiffToolbar;
    var click: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = col, .y = row };
    try std.testing.expect(try tab.handleDiffMouse(&click));
    click.kind = .up;
    try std.testing.expect(try tab.handleDiffMouse(&click));
    try pumpDiffForTests(workbench);
    try std.testing.expectEqual(tab, workbench.activeTab().?);
    const cli = provider.git.?;
    const staged = (try cli.readRef(root, "a.txt", .index)).?;
    defer allocator.free(staged);
    try std.testing.expectEqualStrings(partial, staged);
    const working = (try cli.readRef(root, "a.txt", .working)).?;
    defer allocator.free(working);
    try std.testing.expectEqualStrings(modified, working);
    try std.testing.expectEqualStrings("abc new def stale", try widget.originalModel().borrowLineContent(2));
    try std.testing.expectEqualStrings("abc new def fresh", try widget.modifiedModel().borrowLineContent(2));

    // The selected toolbar disappears when the cursor collapses. Stage the
    // separate last hunk using the hunk toolbar, without staging 'fresh'.
    try widget.modified_editor.setCursorPosition(.{ .lineNumber = 6, .column = 1 });
    try std.testing.expect(widget.gutter_toolbar.selected_mapping == null);
    const gutter = @import("../vs/editor/browser/widget/diffEditor/features/gutterFeature.zig");
    const hunk = widget.state().?.mappings[widget.gutter_toolbar.current_diff.?].line_range_mapping;
    const bounds = gutter.hunkBounds(hunk, widget.original_editor, widget.modified_editor);
    const last_row = bounds.startLineNumber - widget.modified_editor.scrollTop();
    click = .{ .kind = .down, .button = .left, .x = widget.paneWidths().toolbarLeft(widget.sideBySide()), .y = last_row };
    try std.testing.expect(try tab.handleDiffMouse(&click));
    click.kind = .up;
    try std.testing.expect(try tab.handleDiffMouse(&click));
    try pumpDiffForTests(workbench);
    const staged_hunk = (try cli.readRef(root, "a.txt", .index)).?;
    defer allocator.free(staged_hunk);
    try std.testing.expectEqualStrings("alpha\nabc new def stale\nunchanged1\nunchanged2\nunchanged3\nlast NEW\n", staged_hunk);
    try std.testing.expectEqual(@as(usize, 1), widget.changeCount());
}

test "Workbench: git scm integration, shared working files and read-only revision snapshots" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    if (!try runGitTest(allocator, root, &.{"init"})) return error.SkipZigTest;
    try std.testing.expect(try runGitTest(allocator, root, &.{ "config", "core.autocrlf", "false" }));
    _ = try runGitTest(allocator, root, &.{ "symbolic-ref", "HEAD", "refs/heads/main" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.name", "Test User" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "published.txt", .data = "published\n" });
    if (!try runGitTest(allocator, root, &.{ "add", "a.txt", "published.txt" })) return error.SkipZigTest;
    if (!try runGitTest(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "initial" })) return error.SkipZigTest;

    // Working-tree modification (two change blocks), staged addition and
    // untracked file.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\nTWO\nthree\nFOUR\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "staged.txt", .data = "staged\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "untracked.txt", .data = "untracked\n" });
    if (!try runGitTest(allocator, root, &.{ "add", "staged.txt" })) return error.SkipZigTest;

    const path = try std.fmt.allocPrint(allocator, "{s}/a.txt", .{root});
    defer allocator.free(path);
    const staged_path = try std.fmt.allocPrint(allocator, "{s}/staged.txt", .{root});
    defer allocator.free(staged_path);
    const untracked_path = try std.fmt.allocPrint(allocator, "{s}/untracked.txt", .{root});
    defer allocator.free(untracked_path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 100, 30);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const settings_path = try std.fs.path.join(allocator, &.{ root, ".git", "test-settings.json" });
    defer allocator.free(settings_path);
    try workbench.setUserSettingsPaths(&.{settings_path});
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.initGit();

    try std.testing.expect(workbench.git_model.repository != null);
    try std.testing.expect(workbench.scm.changes != null);
    try std.testing.expect(workbench.scm.quick_diff_controller != null);
    const quick_diff = workbench.scm.quick_diff_controller.?;
    try std.testing.expectEqual(@as(usize, 1), quick_diff.count());
    try std.testing.expect(!quick_diff.ignore_trim_whitespace);
    try std.testing.expect(!quick_diff.config.gutter_pattern.added);
    try std.testing.expect(quick_diff.config.gutter_pattern.modified);
    try workbench.setUserConfigurationValue("scm.diffDecorationsGutterPattern.added", .{ .bool = true });
    try std.testing.expect(quick_diff.config.gutter_pattern.added);
    try workbench.setUserConfigurationValue("scm.diffDecorationsIgnoreTrimWhitespace", .{ .string = "inherit" });
    try std.testing.expect(quick_diff.entries.items[0].model.ignore_trim_whitespace);
    try workbench.setUserConfigurationValue("diffEditor.ignoreTrimWhitespace", .{ .bool = false });
    try std.testing.expect(!quick_diff.entries.items[0].model.ignore_trim_whitespace);
    try workbench.setUserConfigurationValue("scm.diffDecorationsIgnoreTrimWhitespace", .{ .string = "true" });
    try std.testing.expect(quick_diff.entries.items[0].model.ignore_trim_whitespace);
    // The change peek is a real embedded diff editor inside the file's ViewZone.
    {
        try workbench.setUserConfigurationValue("scm.diffDecorationsIgnoreTrimWhitespace", .{ .string = "false" });
        const entry = quick_diff.entries.items[0];
        var spins: usize = 0;
        while (entry.model.changes.items.len < 2 and spins < 5000) : (spins += 1) {
            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
            std.Io.sleep(workbench.async_io, .fromMilliseconds(1), .awake) catch {};
        }
        try std.testing.expectEqual(@as(usize, 2), entry.model.changes.items.len);
        const controller = entry.peek_controller orelse return error.TestExpectedQuickDiffController;
        const tab = workbench.activeTab().?;
        var peek_frame: std.Io.Writer.Allocating = .init(allocator);
        defer peek_frame.deinit();
        try renderFrame(workbench, &peek_frame.writer);
        const start_row = tab.view.visibleRowOf(.{ .lineNumber = 2, .column = 1 }).? + tab.editor.top_inset_rows;
        var mouse: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = tab.editor.quickDiffCellColumn(), .y = start_row };
        try std.testing.expect(try tab.view.dispatchMouse(&mouse));
        mouse.kind = .up;
        mouse.default_prevented = false;
        try std.testing.expect(try tab.view.dispatchMouse(&mouse));
        const peek = controller.widget.?;
        const embedded = peek.embedded.?;
        try std.testing.expectEqual(tab.editor.document, embedded.widget.modified_editor.document);
        try std.testing.expectEqualStrings("git", embedded.widget.original_editor.model.uri().scheme);
        try std.testing.expect(!embedded.widget.sideBySide());
        try std.testing.expect(tab.editor.dirty_diff_visible);
        try renderFrame(workbench, &peek_frame.writer);
        try std.testing.expect(embedded.widget.modified_view.isMounted());
        try std.testing.expect(peek.peek.zone.zone_id != null);
        try std.testing.expect(std.mem.indexOf(u8, peek.peek.detail, "1 of 2 changes") != null);
        try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &.{ .key = .f3, .mods = .{ .alt = true } }));
        try std.testing.expectEqual(@as(usize, 1), peek.index);
        try std.testing.expectEqual(embedded, peek.embedded.?);
        try renderFrame(workbench, &peek_frame.writer);
        try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &.{ .key = .f3, .mods = .{ .alt = true, .shift = true } }));
        try std.testing.expectEqual(@as(usize, 0), peek.index);
        try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &.{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } }));
        try std.testing.expect(try terminal_workbench.handleGlobalKey(workbench, &.{ .key = .f2 }));
        try std.testing.expect(peek.child_focused);
        try std.testing.expectEqual(embedded.widget.modified_editor, workbench.code_editor_api.getFocusedCodeEditor().?);
        try std.testing.expectEqual(embedded.widget.modified_editor, workbench.code_editor_api.getFocusedDiffEditor().?.getModifiedControl().?.editor);
        try renderFrame(workbench, &peek_frame.writer);
        const caret = tab.cursorCell() orelse return error.TestExpectedEmbeddedCursor;
        try std.testing.expect(caret.row > @as(usize, @intFromFloat(@max(0, peek.peek.zone.top))));
        var escape: ui.KeyEvent = .{ .key = .escape };
        try std.testing.expect(tab.view.dispatchKey(&escape));
        try std.testing.expect(controller.widget == null);
        try std.testing.expect(!tab.editor.dirty_diff_visible);
        try renderFrame(workbench, &peek_frame.writer);

        // Only providers intersecting the current change appear in the base
        // selector. Selecting another baseline replaces only the original.
        const Quick = @import("../vs/workbench/contrib/scm/common/quickDiff.zig");
        const Alternate = struct {
            fn original(_: *anyopaque, a: std.mem.Allocator, _: []const u8) !?Quick.Original {
                const content = try a.dupe(u8, "one\nalt\nthree\n");
                errdefer a.free(content);
                return .{ .content = content, .ref_label = try a.dupe(u8, "Alternate") };
            }
        };
        var alternate: Quick.QuickDiffProvider = .{ .context = @constCast(&{}), .id = "alternate", .label = "Alternate", .get_original_fn = Alternate.original };
        const service = workbench.scm.quick_diff_service.?;
        _ = try service.addQuickDiffProvider(&alternate);
        defer service.removeProvider(&alternate);
        spins = 0;
        while (entry.model.quick_diffs.len < 3 and spins < 5000) : (spins += 1) {
            _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
            std.Io.sleep(workbench.async_io, .fromMilliseconds(1), .awake) catch {};
        }
        try std.testing.expect(entry.model.quick_diffs.len >= 3);
        try controller.navigate(true, 2);
        const multi = controller.widget.?;
        try std.testing.expect(multi.peek.picker_label.len != 0);
        const switch_action = multi.peek.picker_action.?;
        switch_action.run(switch_action.context);
        const picker = workbench.quick_access.inputService().pickerRef();
        try std.testing.expect(picker.visible);
        for (picker.items.items, 0..) |item, index| if (std.mem.eql(u8, item.id(), "alternate")) {
            picker.setActiveIndex(index);
            break;
        };
        picker.accept();
        try std.testing.expectEqualStrings("alternate", multi.provider_id);
        try std.testing.expectEqual(tab.editor.document, multi.embedded.?.widget.modified_editor.document);
        try renderFrame(workbench, &peek_frame.writer);
        try workbench.commands.execute("closeQuickDiff");
        try std.testing.expect(controller.widget == null);
        try workbench.setUserConfigurationValue("scm.diffDecorationsIgnoreTrimWhitespace", .{ .string = "true" });
    }
    const initial_tabs = workbench.tabCount();
    const provider = workbench.git_model.repository.?;
    try std.testing.expect(provider.count() >= 3);
    try std.testing.expect(workbench.scm.changes.?.resourceCount() >= 3);

    // Direct configuration edits reach both views before the host polls files.
    const graph = workbench.scm.history.?;
    try workbench.setUserConfigurationValue("scm.graph.pageSize", .{ .integer = 1001 });
    try std.testing.expectEqual(@as(usize, 1000), graph.config.page_size);
    try workbench.setUserConfigurationValue("scm.graph.pageSize", .{ .integer = 0 });
    try std.testing.expectEqual(@as(usize, 1), graph.config.page_size);
    try workbench.setUserConfigurationValue("scm.graph.pageSize", null);
    try std.testing.expectEqual(@as(usize, 50), graph.config.page_size);
    try workbench.setUserConfigurationValue("scm.defaultViewMode", .{ .string = "tree" });
    try std.testing.expectEqual(scm_common.ViewMode.tree, workbench.scm.changes.?.viewMode());
    try std.testing.expectEqual(.tree, graph.viewMode());
    graph.setViewMode(.list);
    graph.setViewMode(.tree);
    try workbench.setUserConfigurationValue("scm.defaultViewMode", null);
    try std.testing.expectEqual(.tree, graph.viewMode());
    graph.setViewMode(.list);

    // The Changes view honors the upstream view-mode and sort commands.
    {
        const view = workbench.scm.changes.?;
        try std.testing.expectEqual(scm_common.ViewMode.list, view.viewMode());
        try std.testing.expectEqual(scm_view_mod.ViewSortKey.path, view.viewSortKey());
        _ = try workbench.commands.execute(scm_view_mod.SET_SORT_BY_NAME_ACTION_ID);
        try std.testing.expectEqual(scm_view_mod.ViewSortKey.name, view.viewSortKey());
        _ = try workbench.commands.execute(scm_view_mod.SET_SORT_BY_PATH_ACTION_ID);
        try std.testing.expectEqual(scm_view_mod.ViewSortKey.path, view.viewSortKey());
        _ = try workbench.commands.execute(scm_view_mod.SET_TREE_VIEW_MODE_ACTION_ID);
        try std.testing.expectEqual(scm_common.ViewMode.tree, view.viewMode());
        try std.testing.expect(view.resourceCount() >= 3);
        _ = try workbench.commands.execute(scm_view_mod.SET_LIST_VIEW_MODE_ACTION_ID);
        try std.testing.expectEqual(scm_common.ViewMode.list, view.viewMode());
    }

    // The SCM container stacks the Changes and Graph sections and the Graph
    // lists the repository commits.
    try std.testing.expect(workbench.scm.container != null);
    try std.testing.expect(workbench.scm.view_model != null);
    try std.testing.expect(workbench.scm.history != null);
    const visible_views = try workbench.scm.view_model.?.visibleViews(allocator);
    defer allocator.free(visible_views);
    try std.testing.expectEqual(@as(usize, 2), visible_views.len);
    try std.testing.expectEqualStrings("changes", visible_views[0].id);
    try std.testing.expectEqualStrings("graph", visible_views[1].id);

    workbench.refreshGitStatus();
    const history_view = workbench.scm.history.?;
    try history_view.refresh(.reload);
    try std.testing.expect(history_view.view_models.len > 0);
    try std.testing.expect(history_view.rows.items.len > 0);
    try std.testing.expect(history_view.hasCurrentHistoryItem() or history_view.view_models.len > 0);

    // Collapsing the Graph section keeps the header and gives the space to
    // Changes; rendering both states must not crash.
    _ = try workbench.showActivityById("scm");
    workbench.scm.view_model.?.setCollapsed("graph", true);
    try std.testing.expect(workbench.scm.view_model.?.isCollapsed("graph"));
    var scm_frame: std.Io.Writer.Allocating = .init(allocator);
    defer scm_frame.deinit();
    try renderFrame(workbench, &scm_frame.writer);
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "Source Control") != null);
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "Graph") != null);
    // Changes renders the staged and working groups and their file names.
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "Staged Changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "staged.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "untracked.txt") != null);
    // The Changes tree starts with the branch-aware message input and Commit button.
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "Message (Enter to") != null);
    try std.testing.expect(std.mem.indexOf(u8, scm_frame.written(), "\u{2713} Commit") != null);
    try std.testing.expectEqualStrings(
        "Message (Enter to commit on \"main\")",
        workbench.scm.service_api.?.repositories()[0].input.placeholder(),
    );
    workbench.scm.view_model.?.setCollapsed("graph", false);

    // A mode-1003 idle motion over a section header must not toggle it or run
    // its title actions; only a press does.
    {
        const container = workbench.scm.container.?;
        var changes_header: ?ui.Rect = null;
        for (container.sections.items) |section| {
            if (std.mem.eql(u8, section.id, "changes")) changes_header = section.header_rect;
        }
        const header = changes_header orelse return error.TestExpectedChangesHeader;
        var hover = ui.MouseEvent{
            .kind = .move,
            .x = ui.cell.snap(header.x) + 2,
            .y = ui.cell.snap(header.y),
        };
        try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &hover));
        try std.testing.expect(!workbench.scm.view_model.?.isCollapsed("changes"));
        hover.kind = .click;
        hover.button = .left;
        try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &hover));
        try std.testing.expect(workbench.scm.view_model.?.isCollapsed("changes"));
        try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &hover));
        try std.testing.expect(!workbench.scm.view_model.?.isCollapsed("changes"));
    }

    // Dragging the separator increases Changes and leaves the Graph expanded.
    try renderFrame(workbench, &scm_frame.writer);
    const scm_container = workbench.scm.container.?;
    const sash = scm_container.sashes.items[0].rect;
    const before = scm_container.bodyRect("changes").?.h;
    var drag_sash = ui.MouseEvent{
        .kind = .down,
        .x = ui.cell.snap(sash.x) + 3,
        .y = ui.cell.snap(sash.y),
        .button = .left,
    };
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &drag_sash));
    drag_sash.kind = .move;
    drag_sash.y += 2;
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &drag_sash));
    drag_sash.kind = .up;
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &drag_sash));
    try renderFrame(workbench, &scm_frame.writer);
    try std.testing.expectEqual(before + 2, scm_container.bodyRect("changes").?.h);
    try std.testing.expect(!workbench.scm.view_model.?.isCollapsed("graph"));

    // Pointer motion over the Graph body still drives the row hover: body
    // moves are forwarded to the pane while header moves only track the
    // hovered title action.
    var hover_frame: std.Io.Writer.Allocating = .init(allocator);
    defer hover_frame.deinit();
    try renderFrame(workbench, &hover_frame.writer);
    const graph_body = workbench.scm.container.?.bodyRect("graph") orelse return error.TestExpectedGraphBody;
    var body_move = ui.MouseEvent{ .kind = .move, .x = ui.cell.snap(graph_body.x) + 2, .y = ui.cell.snap(graph_body.y) };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &body_move));
    try std.testing.expect(history_view.hoveredRow() != null);
    try std.testing.expect(history_view.hoverContent() != null);
    history_view.clearHover();

    // The history hover keeps all four rounded corners and the same content
    // inset with either kind of border.
    history_view.hovered_row = 0;
    history_view.hover_content = try allocator.dupe(u8, "7d272ae workbench: report Explorer open failures on click\nA single click opened a preview editor and discarded the change.\nthat Enter and the async open path use, and keep focus in the editor.");
    var hovered_frame: std.Io.Writer.Allocating = .init(allocator);
    defer hovered_frame.deinit();
    const caps = ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,outside,radius\x1b\\").?;
    for ([_]bool{ false, true }) |native| {
        workbench.setCellBorderCapabilities(if (native) caps else null);
        try renderFrame(workbench, &hovered_frame.writer);
        const hover_surface = &(history_view.hover_surface orelse return error.TestExpectedHoverSurface);
        const hover_grid = hover_surface.grid();
        try std.testing.expect(hover_grid.cols >= 12 and hover_grid.rows >= 5);
        const cells = &workbench.frame.prev;
        const left = ui.cell.snap(workbench.activity_bar_part.base.bounds.?.w) + workbench.layout.size(.sidebar) + 1;
        const top = ui.cell.snap(history_view.hoverRect().?.y);
        const right = left + hover_grid.cols - 1;
        const bottom = top + hover_grid.rows - 1;
        const joint = ui.cell_border.Joint;
        for ([_]usize{ left, right, left, right }, [_]usize{ top, top, bottom, bottom }, [_]u32{ '╭', '╮', '╰', '╯' }, [_]u8{ joint.top_left, joint.top_right, joint.bottom_left, joint.bottom_right }) |x, y, glyph, round_joint| {
            if (native) {
                try std.testing.expectEqual(round_joint, cells.borderSetAt(x, y).joints);
            } else {
                try std.testing.expectEqual(glyph, cells.cluster[cells.index(x, y)]);
            }
        }
        try std.testing.expectEqual(@as(u32, '7'), cells.cluster[cells.index(left + 2, top + 2)]);
    }
    workbench.setCellBorderCapabilities(null);
    history_view.clearHover();

    // Expanding the first commit appends its changed-file rows.
    history_view.selection = 0;
    const rows_before_expand = history_view.rows.items.len;
    _ = try history_view.handleKey(&.{ .key = .right });
    try std.testing.expect(history_view.rows.items.len > rows_before_expand);

    // The branch/status entry and activity badge follow the repository.
    try std.testing.expect(workbench.scm.activity.?.status_entry != null);
    try std.testing.expectEqual(@as(usize, provider.count()), workbench.scm.activity.?.count);
    // Count mode follows configuration events, and a selected repository is
    // still active while the Source Control view is not shown.
    try workbench.setUserConfigurationValue("scm.countBadge", .{ .string = "off" });
    try std.testing.expectEqual(@as(usize, 0), workbench.scm.activity.?.count);
    try std.testing.expect(workbench.activity_service.getContainerBadgeDescription("scm") == null);
    const sidebar_was_shown = workbench.geometry().sidebarShown();
    if (sidebar_was_shown) try workbench.toggleSidebar();
    try std.testing.expect(!workbench.geometry().sidebarShown());
    try workbench.setUserConfigurationValue("scm.countBadge", .{ .string = "focused" });
    try std.testing.expectEqual(@as(usize, provider.count()), workbench.scm.activity.?.count);
    if (sidebar_was_shown) try workbench.toggleSidebar();
    try workbench.setUserConfigurationValue("scm.countBadge", .{ .string = "all" });

    // Open the working-tree diff from SCM, which owns the resource path only
    // until the next refresh.
    const working_resource = provider.groups[2].resources.items[0];
    const working_input = workbench.findOpenInput(path).?;
    try std.testing.expectEqualStrings("a.txt", working_resource.relative_path);
    try workbench.scm.changes.?.host.open_change(workbench.scm.changes.?.host.context, &working_resource.iface);
    try pumpDiffForTests(workbench);
    var tab = workbench.activeTab() orelse return error.TestExpectedTab;
    try std.testing.expect(tab.isDiff());
    try std.testing.expectEqual(@as(usize, 2), tab.diff.?.widget.changeCount());
    try std.testing.expect(!tab.editor.isReadOnly());
    try std.testing.expect(tab.diff.?.widget.original_editor.isReadOnly());
    try std.testing.expectEqual(working_input.editor.model, tab.editor.model);
    try std.testing.expectEqualStrings("git", tab.diff.?.widget.originalModel().uri().scheme);
    try std.testing.expectEqualStrings("file", tab.editor.model.uri().scheme);
    try std.testing.expect(tab.diff.?.model.modified_path.ptr != working_resource.absolute_path.ptr);

    // The diff tab composites both panes, the center gutter and its title.
    var diff_frame: std.Io.Writer.Allocating = .init(allocator);
    defer diff_frame.deinit();
    workbench.focusEditor();
    try renderFrame(workbench, &diff_frame.writer);
    try std.testing.expect(std.mem.indexOf(u8, diff_frame.written(), "Index") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff_frame.written(), "Working Tree") != null);
    try std.testing.expect(cursorCell(workbench) != null);

    // The active diff exposes its modified control. An editor command uses
    // the focused side when the user moves focus to the original control.
    const widget = tab.diff.?.widget;
    try std.testing.expect(!widget.options.ignore_trim_whitespace);
    try std.testing.expectEqual(@as(usize, 0), quick_diff.count());
    try std.testing.expectEqual(widget.modified_editor, workbench.code_editor_api.getActiveCodeEditor().?);
    widget.setFocus(.original);
    try std.testing.expectEqual(widget.original_editor, workbench.code_editor_api.getFocusedCodeEditor().?);
    try workbench.commands.execute("editor.action.copyLinesDownAction");
    try std.testing.expect(!widget.original_editor.isDirty());
    widget.setFocus(.modified);

    // Navigation keys are TUI-specific (Alt-Up/Alt-Down).
    const before_change = tab.diff.?.widget.current_change;
    const next_key = ui.KeyEvent{ .key = .down, .mods = .{ .alt = true } };
    const result = try terminal_workbench.handleTabKey(workbench, &next_key);
    try std.testing.expectEqual(TabKeyResult.handled, result);
    try std.testing.expect(tab.diff.?.widget.current_change != before_change);
    const previous_key = ui.KeyEvent{ .key = .up, .mods = .{ .alt = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try terminal_workbench.handleTabKey(workbench, &previous_key));
    try std.testing.expectEqual(before_change, tab.diff.?.widget.current_change);

    // A comparison edits the same working resource and forwards dirty state;
    // the revision side remains immutable. Undo restores the file contents.
    try std.testing.expectError(error.ReadOnly, widget.original_editor.save());
    try widget.modified_editor.setCursorPosition(.{ .lineNumber = 1, .column = 1 });
    try widget.modified_editor.insertText("x");
    try std.testing.expect(tab.input.isDirty());
    try std.testing.expect(working_input.editor.isDirty());
    try std.testing.expectEqualStrings("xone", try working_input.editor.model.borrowLineContent(1));
    try widget.modified_editor.undo();
    try std.testing.expect(!tab.input.isDirty());
    try std.testing.expect(!working_input.editor.isDirty());
    _ = try tab.input.save(0);
    try std.testing.expectEqualStrings("one", try working_input.editor.model.borrowLineContent(1));

    // Staged and untracked diffs open with distinct titles/keys.
    try workbench.openDiff(staged_path, .head, .index);
    try pumpDiffForTests(workbench);
    const staged_tab = workbench.activeTab().?;
    try std.testing.expect(staged_tab.isDiff());
    try std.testing.expect(staged_tab.editor.isReadOnly());
    try std.testing.expectEqualStrings("git", staged_tab.editor.model.uri().scheme);
    try std.testing.expect(std.mem.indexOf(u8, staged_tab.input.getName(), "HEAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_tab.input.getName(), "Index") != null);

    // Index <-> working tree diff for a file that was staged and then edited.
    try tmp.dir.writeFile(io, .{ .sub_path = "staged.txt", .data = "staged\nmore\n" });
    try workbench.openDiff(staged_path, .index, .working);
    try pumpDiffForTests(workbench);
    const index_working_tab = workbench.activeTab().?;
    try std.testing.expect(index_working_tab.isDiff());
    try std.testing.expect(!index_working_tab.editor.isReadOnly());
    try std.testing.expectEqualStrings("file", index_working_tab.editor.model.uri().scheme);
    try std.testing.expect(std.mem.indexOf(u8, index_working_tab.input.getName(), "Index") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_working_tab.input.getName(), "Working Tree") != null);
    // Snapshot identities use the filesystem path, not its spelling.
    const staged_alias = try std.fmt.allocPrint(allocator, "{s}/./staged.txt", .{root});
    defer allocator.free(staged_alias);
    try std.testing.expect(index_working_tab.diff.?.matches(staged_alias, "Index", "Working Tree"));

    try workbench.openDiff(untracked_path, .empty, .working);
    try pumpDiffForTests(workbench);
    const untracked_tab = workbench.activeTab().?;
    try std.testing.expect(untracked_tab.isDiff());
    try std.testing.expectEqual(initial_tabs + 4, workbench.tabCount());

    // Reopening from the rebuilt SCM rows refreshes and activates the same tab.
    workbench.refreshGitStatus();
    const refreshed_resource = provider.groups[2].resources.items[0];
    try std.testing.expectEqualStrings("a.txt", refreshed_resource.relative_path);
    try workbench.scm.changes.?.host.open_change(workbench.scm.changes.?.host.context, &refreshed_resource.iface);
    try pumpDiffForTests(workbench);
    try std.testing.expectEqual(tab, workbench.activeTab().?);
    try std.testing.expectEqual(initial_tabs + 4, workbench.tabCount());

    // Git chooses index -> working for a partially staged resource, and the
    // editor service reuses its already-open snapshot pane.
    var partially_staged: ?*@import("../extensions/git/src/repository.zig").GitScmResource = null;
    for (provider.groups[2].resources.items) |resource| {
        if (std.mem.eql(u8, resource.relative_path, "staged.txt")) {
            partially_staged = resource;
            break;
        }
    }
    const staged_resource = partially_staged orelse return error.TestExpectedPartiallyStagedResource;
    try workbench.scm.changes.?.host.open_change(workbench.scm.changes.?.host.context, &staged_resource.iface);
    try pumpDiffForTests(workbench);
    try std.testing.expectEqual(index_working_tab, workbench.activeTab().?);
    try std.testing.expectEqual(initial_tabs + 4, workbench.tabCount());

    // Opening a changed file from the Graph uses the parent/commit snapshot
    // diff; root commits compare against the empty tree.
    var change_row: ?usize = null;
    for (history_view.rows.items, 0..) |row, row_index| {
        if (std.meta.activeTag(row) == .change) {
            change_row = row_index;
            break;
        }
    }
    try std.testing.expect(change_row != null);
    history_view.selection = change_row.?;
    _ = try history_view.handleKey(&.{ .key = .enter });
    try pumpDiffForTests(workbench);
    const commit_tab = workbench.activeTab() orelse return error.TestExpectedTab;
    try std.testing.expect(commit_tab.isDiff());
    try std.testing.expect(std.mem.indexOf(u8, commit_tab.input.getName(), "\u{2194}") != null);
    try std.testing.expect(std.mem.indexOf(u8, commit_tab.input.getName(), "Empty") != null);

    // Git resource inputs have no upstream text-resource serializer, so
    // their composite diff input cannot be serialized.
    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    var file_serializer = workbench.createFileSerializer();
    defer file_serializer.deinit();
    try registry.registerEditorSerializer(FileEditorInput.TYPE_ID, file_serializer.interface());
    const diff_input = @import("../vs/workbench/common/editor/diffEditorInput.zig");
    var diff_serializer = diff_input.DiffEditorSerializer.init(allocator, &registry);
    try registry.registerEditorSerializer(diff_input.ID, diff_serializer.interface());
    var serialized = try workbench.part.createState(allocator, &registry);
    defer serialized.deinit(allocator);
    var serialized_editors: usize = 0;
    for (serialized.groups) |group_data| serialized_editors += group_data.editors.len;
    // Only the normal file tab is serialized; the three Git revision
    // comparisons cannot serialize both resource sides.
    try std.testing.expectEqual(initial_tabs, serialized_editors);

    // A working file that was first resolved by a comparison can be opened
    // separately without a duplicate working copy.
    const working_model = index_working_tab.editor.model;
    try workbench.openPath(staged_path);
    const staged_file_tab = workbench.activeTab().?;
    try std.testing.expect(!staged_file_tab.isDiff());
    try std.testing.expectEqual(working_model, staged_file_tab.editor.model);
    try std.testing.expect(workbench.workingCopyService().hasResource(staged_file_tab.editor.path));
    _ = try workbench.closeActive();
    try std.testing.expect(workbench.workingCopyService().hasResource(index_working_tab.editor.path));

    // Quick-diff decorations can be disabled and detach the gutter cell.
    try workbench.openPath(path);
    const file_tab = workbench.activeTab().?;
    try std.testing.expect(!file_tab.isDiff());
    try std.testing.expect(quick_diff.contains(file_tab.editor));
    try workbench.setUserConfigurationValue("scm.diffDecorations", .{ .string = "none" });
    try std.testing.expectEqual(@as(usize, 0), file_tab.editor.lineDecorationsWidth());
    try std.testing.expectEqual(@as(usize, 0), quick_diff.count());
    try workbench.setUserConfigurationValue("scm.diffDecorations", .{ .string = "overview" });
    try std.testing.expect(quick_diff.contains(file_tab.editor));
    try std.testing.expectEqual(@as(usize, 0), file_tab.editor.lineDecorationsWidth());
    try workbench.setUserConfigurationValue("scm.diffDecorations", .{ .string = "all" });
    try std.testing.expectEqual(@as(usize, 1), file_tab.editor.lineDecorationsWidth());

    // The commit input commits the index. The `git.commit` command reads the
    // SCM input model, like upstream's command.
    {
        var input = workbench.scm.service_api.?.repositories()[0].input;
        input.setValue("scm commit message", false);
        workbench.scm.changes.?.refresh();
        try std.testing.expect(provider.repository.stateRef().index_changes.len > 0);
        // SCMActionButton now consumes the Git provider's grouped secondary
        // commands, rather than building Git-specific rows in Workbench.
        try workbench.scm.changes.?.showCommitMenu(.{ .x = 1, .y = 1 });
        const commit_rows = workbench.context_menu_service.current.?.items.items;
        try std.testing.expectEqual(@as(usize, 5), commit_rows.len);
        try std.testing.expectEqualStrings("Commit", commit_rows[0].label);
        try std.testing.expectEqualStrings("Commit (Amend)", commit_rows[1].label);
        try std.testing.expectEqual(ui.ContextMenuItemType.separator, commit_rows[2].type);
        try std.testing.expectEqualStrings("Commit & Push", commit_rows[3].label);
        try std.testing.expectEqualStrings("Commit & Sync", commit_rows[4].label);
        workbench.context_menu_service.hideContextMenu();
        _ = try workbench.commands.execute("git.commit");
        const after_commit = provider.repository.stateRef();
        try std.testing.expectEqual(@as(usize, 0), after_commit.index_changes.len);
        try std.testing.expect(after_commit.working_tree_changes.len > 0);
        try std.testing.expectEqualStrings("", input.value());
        const subject = try captureGitTest(allocator, root, &.{ "log", "-1", "--pretty=%s" });
        defer if (subject) |text| allocator.free(text);
        try std.testing.expect(subject != null);
        try std.testing.expect(std.mem.indexOf(u8, subject.?, "scm commit message") != null);

        // With an empty index the terminal's smart-commit path stages the
        // changed files before committing.
        input.setValue("smart commit", false);
        workbench.scm.changes.?.refresh();
        _ = try workbench.commands.execute("git.commit");
        const after_smart = provider.repository.stateRef();
        try std.testing.expectEqual(@as(usize, 0), after_smart.index_changes.len);
        try std.testing.expectEqual(@as(usize, 0), after_smart.working_tree_changes.len);
        try std.testing.expectEqual(@as(usize, 0), after_smart.untracked_changes.len);
        const smart_subject = try captureGitTest(allocator, root, &.{ "log", "-1", "--pretty=%s" });
        defer if (smart_subject) |text| allocator.free(text);
        try std.testing.expect(smart_subject != null);
        try std.testing.expect(std.mem.indexOf(u8, smart_subject.?, "smart commit") != null);
    }
}

test "Workbench: SCM headers toggle on click and Load More pages the history" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    if (!try runGitTest(allocator, root, &.{"init"})) return error.SkipZigTest;
    _ = try runGitTest(allocator, root, &.{ "symbolic-ref", "HEAD", "refs/heads/main" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.name", "Test User" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.email", "test@example.com" });
    var number: usize = 0;
    while (number < 4) : (number += 1) {
        const contents = try std.fmt.allocPrint(allocator, "commit {d}\n", .{number});
        defer allocator.free(contents);
        try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = contents });
        if (!try runGitTest(allocator, root, &.{ "add", "a.txt" })) return error.SkipZigTest;
        const message = try std.fmt.allocPrint(allocator, "commit {d}", .{number});
        defer allocator.free(message);
        if (!try runGitTest(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", message })) return error.SkipZigTest;
    }

    const path = try std.fmt.allocPrint(allocator, "{s}/a.txt", .{root});
    defer allocator.free(path);

    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 100, 30);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.initGit();
    _ = try workbench.showActivityById("scm");
    try workbench.layout.setSize(.sidebar, 40);

    const view = workbench.scm.history orelse return error.TestExpectedHistoryView;
    view.setConfig(.{ .page_size = 2, .page_on_scroll = false });
    try view.refresh(.reload);
    try std.testing.expectEqual(@as(usize, 3), view.rows.items.len);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);

    const container = workbench.scm.container orelse return error.TestExpectedScmContainer;

    // Pointer motion over the Graph header never collapses the section and
    // never runs a title action; only a left click does. Hovering a title
    // action marks it in the ui surface's hover chain, which paints its
    // declared hover style.
    const header = container.sections.items[1].header_rect;
    const graph_header_y = ui.cell.snap(header.y);
    const header_start = ui.cell.snap(header.x);
    const header_end = header_start + ui.cell.snap(header.w);
    const header_surface = &(container.headers.items[3].surface orelse return error.TestExpectedScmContainer);
    var over_title = ui.MouseEvent{ .kind = .move, .x = header_start + 1, .y = graph_header_y };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &over_title));
    try std.testing.expect(!container.model.isCollapsed("graph"));
    for (container.headers.items[3].nodes.items) |entry| {
        if (entry.id.len != 0) try std.testing.expect(!entry.node.isHovered());
    }
    var action_x: ?usize = null;
    var scan = header_end;
    while (scan > header_start) {
        scan -= 1;
        const hit = container.hitTest(header, scan, graph_header_y) orelse continue;
        if (hit == .action and std.mem.eql(u8, hit.action.action, scm_history_view_mod.GRAPH_MENU_ACTION_ID)) {
            action_x = scan;
            break;
        }
    }
    try std.testing.expect(action_x != null);
    const mode_before = view.view_mode;
    var over_action = ui.MouseEvent{ .kind = .move, .x = action_x.?, .y = graph_header_y };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &over_action));
    try std.testing.expectEqual(mode_before, view.view_mode);
    try std.testing.expect(!container.model.isCollapsed("graph"));
    const hovered = header_surface.document().hoverTarget();
    try std.testing.expect(hovered != null);
    var on_action = false;
    for (container.headers.items[3].nodes.items) |entry| {
        if (entry.id.len != 0 and entry.node == hovered.?) on_action = true;
    }
    try std.testing.expect(on_action);

    const graph_press = ui.MouseEvent{ .kind = .down, .button = .left, .x = action_x.?, .y = graph_header_y };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &graph_press));
    try std.testing.expect(workbench.context_menu_service.current != null);
    const graph_menu = workbench.context_menu_service.current.?.popup.?;
    try std.testing.expect(!workbench.isQuickAccessOpen());
    try std.testing.expectEqual(graph_press.x, graph_menu.options.x.?);
    try std.testing.expectEqual(graph_press.y, graph_menu.options.y.?);
    try std.testing.expectEqualStrings("View as List", graph_menu.items[0].label);
    try std.testing.expectEqual(mode_before == .list, graph_menu.items[0].checked);
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .end }));
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .enter }));
    try std.testing.expectEqual(.tree, view.viewMode());
    view.setViewMode(mode_before);

    const changes = workbench.scm.changes.?;
    changes.setViewMode(.tree);
    try workbench.commands.execute(scm_view_mod.CHANGES_MENU_ACTION_ID);
    const changes_menu = workbench.context_menu_service.current.?.popup.?;
    try std.testing.expectEqualStrings("View & Sort", changes_menu.items[0].label);
    try std.testing.expect(changes_menu.items[0].submenu[1].checked);
    try std.testing.expect(!changes_menu.items[0].submenu[3].enabled);
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .home }));
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .right }));
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .enter }));
    try std.testing.expectEqual(.list, changes.viewMode());

    const header_context = ui.MouseEvent{ .kind = .down, .button = .right, .x = header_start + 1, .y = graph_header_y };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &header_context));
    const view_items = workbench.context_menu_service.current.?.popup.?.items;
    try std.testing.expectEqualStrings("Graph", view_items[view_items.len - 1].label);
    try std.testing.expect(view_items[view_items.len - 1].checked);
    try std.testing.expect(workbench.context_menu_service.handleKey(&.{ .key = .escape }));

    // Moving back over the title clears the action hover.
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &over_title));
    for (container.headers.items[3].nodes.items) |entry| {
        if (entry.id.len != 0) try std.testing.expect(!entry.node.isHovered());
    }

    // The left click toggles the section; a second click restores it for the
    // Load More click below.
    var header_click = ui.MouseEvent{ .kind = .click, .x = header_start + 1, .y = graph_header_y, .button = .left };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &header_click));
    try std.testing.expect(container.model.isCollapsed("graph"));
    try renderFrame(workbench, &out.writer);
    const collapsed_y = ui.cell.snap(container.sections.items[1].header_rect.y);
    var expand_click = ui.MouseEvent{ .kind = .click, .x = header_start + 1, .y = collapsed_y, .button = .left };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &expand_click));
    try std.testing.expect(!container.model.isCollapsed("graph"));
    try renderFrame(workbench, &out.writer);

    const body = container.bodyRect("graph") orelse return error.TestExpectedGraphBody;
    try std.testing.expect(ui.cell.snap(body.h) >= 3);
    const x = ui.cell.snap(body.x) + 2;
    const y = ui.cell.snap(body.y) + 2;
    var click = ui.MouseEvent{ .kind = .down, .x = x, .y = y, .button = .left };
    try std.testing.expect(terminal_workbench.handleSidebarMouse(workbench, &click));
    try std.testing.expectEqual(@as(usize, 4), view.rows.items.len);
}

fn seedFile(allocator: Allocator, io: Io, tmp: *std.testing.TmpDir, name: []const u8, contents: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
    errdefer allocator.free(path);
    if (std.fs.path.dirname(path)) |directory| {
        Io.Dir.cwd().createDirPath(io, directory) catch {};
    }
    var editor = try Editor.createFromText(allocator, io, contents, path, 40, 7);
    try editor.save();
    editor.deinit();
    allocator.destroy(editor);
    return path;
}

fn pumpSidebarForTests(workbench: *Workbench) void {
    const sidebar = workbench.sidebar orelse return;
    var guard: usize = 0;
    while (sidebar.hasPendingLoad() and guard < 1000) : (guard += 1) {
        _ = sidebar.pollLoad();
        if (sidebar.hasPendingLoad()) std.Io.sleep(workbench.async_io, .fromMilliseconds(1), .awake) catch {};
    }
}

fn sendDragMouse(workbench: *Workbench, report: usize, x: usize, y: usize, release: bool) !void {
    var buf: [64]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ report, x + 1, y + 1, @as(u8, if (release) 'm' else 'M') });
    var decoded = try ui.input.decode(workbench.allocator, bytes);
    defer decoded.deinit(workbench.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.items.len);
    const mouse = &decoded.items[0].mouse;
    if (terminal_workbench.handleTabDragMouse(workbench, mouse)) return;
    if (terminal_workbench.handleSashMouse(workbench, mouse)) return;
    _ = terminal_workbench.handleTabMouse(workbench, mouse);
}

fn sidebarMouseForTest(workbench: *Workbench, kind: ui.MouseKind, x: usize) !void {
    try std.testing.expect(terminal_workbench.handleSashMouse(workbench, &.{ .kind = kind, .x = x, .y = 2, .button = .left }));
}

fn runGitTest(allocator: Allocator, root: []const u8, args: []const []const u8) !bool {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.append("-C");
    try argv.append(root);
    try argv.appendSlice(args);
    const result = std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(20_000), .clock = .awake } },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn captureGitTest(allocator: Allocator, root: []const u8, args: []const []const u8) !?[]u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.append("-C");
    try argv.append(root);
    try argv.appendSlice(args);
    const result = std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(20_000), .clock = .awake } },
    }) catch return null;
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) {
        allocator.free(result.stdout);
        return null;
    }
    return result.stdout;
}

fn launchTestTerminal(service: *TerminalService, allocator: Allocator) anyerror!*terminal_service_mod.TerminalInstance {
    const instance = try terminal_service_mod.TerminalInstance.create(allocator, service.io, service.next_id, .{
        .shell = "/bin/true",
        .profile_name = "true",
    });
    service.next_id += 1;
    return instance;
}

test "workbench context keys observe part visibility and dirty working copies between input events" {
    const allocator = std.testing.allocator;
    const io = time_compat.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "context.txt", "one");
    defer allocator.free(path);
    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 16);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const keys = try workbench.ensureContextKeys();
    try std.testing.expect(keys.getValue("mainEditorAreaVisible").boolean);
    try std.testing.expect(!keys.getValue("dirtyWorkingCopies").boolean);
    try workbench.layout.setPartHidden(false, .panel);
    try std.testing.expect(keys.getValue("panelVisible").boolean);
    try workbench.layout.setPartHidden(true, .panel);
    try std.testing.expect(!keys.getValue("panelVisible").boolean);
    const editor = workbench.activeTab().?.editor;
    try editor.insertText("two");
    try std.testing.expect(keys.getValue("dirtyWorkingCopies").boolean);
    try editor.save();
    try std.testing.expect(!keys.getValue("dirtyWorkingCopies").boolean);
}

test "Simple Browser command and API apply the same URL restrictions before terminal launch" {
    const allocator = std.testing.allocator;
    const io = time_compat.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "browser.txt", "");
    defer allocator.free(path);
    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 72, 16);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    try std.testing.expectError(error.InvalidBrowserAddress, workbench.simple_browser.show("file:///etc/hosts"));
    try std.testing.expectError(error.InvalidBrowserAddress, workbench.simple_browser.show("https://example.org/a\rb"));
    try workbench.commands.execute("simpleBrowser.show");
    const picker = workbench.quick_access.inputService().pickerRef();
    try picker.setValue("file:///etc/hosts");
    picker.accept();
    try std.testing.expectEqualStrings("Simple Browser requires an HTTP or HTTPS URL.", workbench.activeTab().?.editor.message());
    try std.testing.expectEqual(@as(usize, 0), workbench.terminalCount());
}

test "Ports commands use the registered workspace tunnel provider" {
    const api = @import("../vs/workbench/api/common/extensionApi.zig");
    const Terminal = struct {
        launches: usize = 0,
        alive: bool = false,
        interrupted: bool = false,

        fn create(context: *anyopaque, options: api.TerminalOptions) !usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("devtunnel", options.shell_path);
            try std.testing.expectEqualStrings("Forward Port 3000", options.name);
            try std.testing.expectEqual(@as(usize, 3), options.shell_args.len);
            try std.testing.expectEqualStrings("host", options.shell_args[0]);
            try std.testing.expectEqualStrings("-p", options.shell_args[1]);
            try std.testing.expectEqualStrings("3000", options.shell_args[2]);
            self.launches += 1;
            self.alive = true;
            return 42;
        }

        fn running(context: *anyopaque, id: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return id == 42 and self.alive;
        }

        fn send(context: *anyopaque, id: usize, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.interrupted = id == 42 and std.mem.eql(u8, message, "\x03");
            self.alive = false;
        }
    };
    var terminal = Terminal{};
    const w_window = try TestWindow.init(std.testing.allocator, std.testing.io, &.{}, 80, 24);
    const w = w_window.workbench;
    defer w_window.deinit();
    w.builtin_host.tunnel_provider.terminals = .{ .context = &terminal, .create = Terminal.create, .running = Terminal.running, .send_text = Terminal.send };
    const picker = w.quick_access.inputService().pickerRef();
    try w.commands.execute("remote.tunnel.closeCommandPalette");
    picker.accept();
    try std.testing.expectEqualStrings("Port number or address (eg. 3000 or 10.10.10.10:2000).", picker.placeholder);
    try picker.setValue("localhost:3000");
    picker.accept();
    try std.testing.expectEqual(@as(usize, 1), terminal.launches);
    for ([_][]const u8{ "3000", "127.0.0.1:3000", "65536", "host..invalid:80", "outside.example:3000" }) |input| {
        try w.commands.execute("remote.tunnel.forwardCommandPalette");
        try picker.setValue(input);
        picker.accept();
        try std.testing.expectEqual(@as(usize, 1), terminal.launches);
    }
    try w.commands.execute("remote.tunnel.closeCommandPalette");
    try std.testing.expectEqualStrings("Port 3000", picker.items.items[0].item.label);
    picker.accept();
    try std.testing.expect(terminal.interrupted);
    try w.commands.execute("remote.tunnel.closeCommandPalette");
    try std.testing.expectEqualStrings("No ports currently forwarded. Try running the Forward a Port command", picker.items.items[0].item.label);
}

test "workbench restores scoped layout and honors zenMode.restore on reopening" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const LayoutStorage = @import("layoutStorage.zig").LayoutStorage;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try seedFile(allocator, io, &tmp, "notes.txt", "one");
    defer allocator.free(file);
    const root = std.fs.path.dirname(file).?;
    const settings = try seedFile(allocator, io, &tmp, "settings.json", "{}");
    defer allocator.free(settings);

    {
        const wb_window = try TestWindow.init(allocator, io, &.{file}, 100, 40);
        const wb = wb_window.workbench;
        defer wb_window.deinit();
        try wb.setWorkspaceFolders(&.{root});
        try wb.initSidebarFromWorkspace();
        try std.testing.expect(try wb.openPanelContainer(PROBLEMS_CONTAINER_ID));
        try wb.layout.setSize(.sidebar, 36);
        try wb.layout.setSize(.panel, 12);
        try wb.toggleZenMode(false, false);
        try std.testing.expect(wb.layout.isMainEditorCentered());
        var storage = try LayoutStorage.init(wb.allocator, wb.io, wb.layout, wb.workspace.getWorkspace().folders.items, root, null);
        defer storage.deinit();
        _ = try wb.core.on_will_shutdown.listen(&storage, LayoutStorage.save);
        try wb.lifecycle.shutdown(.quit);
    }

    for ([_]bool{ true, false }) |restore_zen| {
        const wb_window = try TestWindow.init(allocator, io, &.{file}, 100, 40);
        const wb = wb_window.workbench;
        defer wb_window.deinit();
        try wb.setUserSettingsPaths(&.{settings});
        try wb.setWorkspaceFolders(&.{root});
        try wb.initSidebarFromWorkspace();
        try wb.setUserConfigurationValue("zenMode.restore", .{ .bool = restore_zen });
        var storage = try LayoutStorage.init(wb.allocator, wb.io, wb.layout, wb.workspace.getWorkspace().folders.items, root, null);
        defer storage.deinit();
        try std.testing.expect(try storage.load(true) == null);
        try std.testing.expect(!wb.layout.isZenModeActive());
        try std.testing.expectEqual(28, wb.sidebar_part.width);
        try wb.layout.restoreParts(try storage.load(false), &wb.part.when_restored);
        try std.testing.expectEqual(restore_zen, wb.layout.isZenModeActive());
        try std.testing.expectEqual(restore_zen, wb.layout.isMainEditorCentered());
        try std.testing.expectEqual(!restore_zen, wb.layout.isVisible(.sidebar));
        try std.testing.expectEqual(!restore_zen, wb.geometry().panelShown());
        if (restore_zen) try wb.toggleZenMode(false, false);
        try std.testing.expect(wb.layout.isVisible(.sidebar));
        try std.testing.expect(wb.geometry().panelShown());
        try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, wb.geometry().activePanelId());
        try std.testing.expect(!wb.layout.isMainEditorCentered());
        try std.testing.expectEqual(36, wb.sidebar_part.width);
        try std.testing.expectEqual(12, wb.panel_part.getSize());
    }

    // Another window in the profile gets the shared sizes and its own layout.
    const wb_window = try TestWindow.init(allocator, io, &.{}, 100, 40);
    const wb = wb_window.workbench;
    defer wb_window.deinit();
    var storage = try LayoutStorage.init(wb.allocator, wb.io, wb.layout, wb.workspace.getWorkspace().folders.items, root, "other.session");
    defer storage.deinit();
    try wb.layout.restoreParts(try storage.load(false), &wb.part.when_restored);
    try std.testing.expect(!wb.layout.isZenModeActive());
    try std.testing.expect(!wb.geometry().panelShown());
    try std.testing.expectEqual(36, wb.sidebar_part.width);
    try std.testing.expectEqual(12, wb.panel_part.getSize());
}

test "terminal shutdown history preserves recent order, selection and closed editor batch IDs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const History = @import("../vs/workbench/services/history/browser/historyService.zig").HistoryService;
    const HistoryStorage = @import("historyStorage.zig").HistoryStorage;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "history.json",
        \\{"version":1,"recent":["a","b"],"closed":[{"path":"b","group_id":3,"index":2,"sticky":false,"pinned":true,"batch_id":17}],"navigation":[{"path":"a","group_id":3,"top_view_line":9,"selection":{"start_line":10,"start_column":3,"end_line":10,"end_column":3,"selection_start_line":10,"selection_start_column":3,"position_line":10,"position_column":3}}]}
    );
    defer allocator.free(path);
    for (0..2) |_| {
        var history = History.init(allocator);
        defer history.deinit();
        var store = HistoryStorage{ .allocator = allocator, .io = io, .path = path, .history = &history };
        try store.load();
        try std.testing.expectEqualStrings("a", history.getHistory()[0]);
        try std.testing.expectEqualStrings("b", history.getHistory()[1]);
        try std.testing.expectEqual(17, history.closed_batch_id);
        try std.testing.expectEqual(1, history.closed_editors.items.len);
        const entry = history.default_stacks.selections.current().?;
        try std.testing.expectEqual(9, entry.top_view_line);
        try std.testing.expectEqual(10, entry.selection.?.restore(.{}).selection.?.positionLineNumber);
        try HistoryStorage.save(.{ .reason = .quit }, &store);
    }
}

test "workbench restores after editor completion or two seconds and eventually waits for idle" {
    const allocator = std.testing.allocator;
    const WindowTimer = @import("../vs/base/common/async.zig").WindowTimer;
    const Phase = @import("../vs/workbench/services/lifecycle/common/lifecycle.zig").LifecyclePhase;
    const Clock = struct {
        ms: i64 = 0,

        fn now(context: *anyopaque) i64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.ms;
        }
    };
    for ([_]bool{ false, true }) |slow| {
        const wb_window = try TestWindow.init(allocator, std.testing.io, &.{}, 80, 24);
        const wb = wb_window.workbench;
        defer wb_window.deinit();
        // Model an editor group whose visible editor has not resolved yet.
        if (slow) wb.part.when_restored = .{};
        var clock = Clock{};
        var timer = WindowTimer{ .clock = .{ .context = &clock, .now = Clock.now } };
        // Workbench.startup has already initiated restore and attached its
        // continuation, while native profile/storage input is still pending.
        try std.testing.expectEqual(@as(usize, 1), wb.core.restore_state_ready.pending.items.len);
        try std.testing.expect(!wb.layout.when_ready.is_open);
        try wb.core.provideRestoreState(&timer, null);
        try std.testing.expectError(error.WorkbenchAlreadyRestoring, wb.core.provideRestoreState(&timer, null));
        try std.testing.expect(wb.layout.when_ready.is_open);
        try std.testing.expectEqual(!slow, wb.layout.isRestored());
        if (slow) {
            try std.testing.expectEqual(Phase.Ready, wb.lifecycle.phase);
            clock.ms = 1999;
            try timer.dispatch(true);
            try std.testing.expectEqual(Phase.Ready, wb.lifecycle.phase);
            try std.testing.expectEqual(1, timer.nextTimeout(250));
            clock.ms = 2000;
            try timer.dispatch(false);
        }
        try std.testing.expectEqual(Phase.Restored, wb.lifecycle.phase);
        if (slow) {
            clock.ms += 200;
            try wb.part.when_restored.open(allocator);
            try std.testing.expect(wb.layout.isRestored());
        }
        clock.ms = if (slow) 4499 else 2499;
        try timer.dispatch(true);
        try std.testing.expectEqual(Phase.Restored, wb.lifecycle.phase);
        clock.ms += 1;
        try timer.dispatch(false);
        try std.testing.expectEqual(Phase.Restored, wb.lifecycle.phase);
        if (slow) {
            clock.ms += 2499;
            try timer.dispatch(false);
            try std.testing.expectEqual(Phase.Restored, wb.lifecycle.phase);
            clock.ms += 1;
        }
        try timer.dispatch(!slow);
        try std.testing.expectEqual(Phase.Eventually, wb.lifecycle.phase);
        try std.testing.expectEqual(250, timer.nextTimeout(250));
    }
}

test "workbench shutdown cancels outstanding restore and idle callbacks" {
    const allocator = std.testing.allocator;
    const WindowTimer = @import("../vs/base/common/async.zig").WindowTimer;
    const Phase = @import("../vs/workbench/services/lifecycle/common/lifecycle.zig").LifecyclePhase;
    for ([_]bool{ false, true }) |restoring| {
        const wb_window = try TestWindow.init(allocator, std.testing.io, &.{}, 80, 24);
        const wb = wb_window.workbench;
        defer wb_window.deinit();
        if (restoring) wb.part.when_restored = .{};
        var now_ms: i64 = 0;
        var timer = WindowTimer{ .clock = .{ .context = &now_ms, .now = struct {
            fn now(ctx: *anyopaque) i64 {
                const time: *i64 = @ptrCast(@alignCast(ctx));
                return time.*;
            }
        }.now } };
        try wb.core.provideRestoreState(&timer, null);
        now_ms = 2500;
        if (!restoring) try timer.dispatch(false);
        try wb.lifecycle.shutdown(.quit);
        try wb.part.when_restored.open(allocator);
        now_ms = 5000;
        try timer.dispatch(true);
        try std.testing.expect(timer.callback == null);
        try std.testing.expectEqual(if (restoring) Phase.Ready else Phase.Restored, wb.lifecycle.phase);
    }
}

test "disposing a constructed workbench before startup leaves the window empty" {
    const allocator = std.testing.allocator;
    var surface: ui.Surface = undefined;
    try @import("workbench.zig").initWindowSurface(&surface, allocator, 48, 16);
    defer surface.deinit();
    var services = try @import("../vs/workbench/workbench.common.main.zig").createServices(allocator);
    defer services.deinit();
    const wb = try Workbench.init(allocator, std.testing.io, @import("./editorView.zig").View.createHandle, &surface, &services, .{}, null);
    try std.testing.expectEqual(.Starting, wb.lifecycle.phase);
    wb.deinit();
    try std.testing.expect(surface.document().root.?.first_child == null);
}

test "workbench mounts and disposes only its subtree in the terminal window" {
    var surface: ui.Surface = undefined;
    try @import("workbench.zig").initWindowSurface(&surface, std.testing.allocator, 48, 16);
    defer surface.deinit();
    const doc = surface.document();
    const parent = doc.root.?;
    const sibling = try doc.createElement(.div);
    _ = try parent.appendChild(sibling);
    {
        const models = @import("../vs/editor/contrib/documentSymbols/browser/outlineModel.zig");
        var supplied_models = models.OutlineModelService.init(std.testing.allocator);
        defer supplied_models.deinit();
        var services = try @import("../vs/workbench/workbench.common.main.zig").createServices(std.testing.allocator);
        defer services.deinit();
        _ = try services.set(models.outline_model_service_id, &supplied_models);
        const wb = try Workbench.init(std.testing.allocator, std.testing.io, @import("./editorView.zig").View.createHandle, &surface, &services, .{}, null);
        defer wb.deinit();
        try std.testing.expect(wb.layout.main_container == null);
        try std.testing.expect(sibling.nextSibling() == null);
        const instantiation = try wb.startup();
        try std.testing.expectEqual(wb.instantiation, instantiation);
        try std.testing.expectError(error.WorkbenchAlreadyStarted, wb.startup());
        try std.testing.expectEqual(&supplied_models, try wb.instantiation.invokeFunction(models.getOutlineModelService, .{}));
        const main = wb.layout.main_container.?;
        try std.testing.expectEqual(parent, main.parent.?);
        try std.testing.expectEqual(main, sibling.nextSibling().?);
        try std.testing.expectEqual(parent, doc.root.?);
        try std.testing.expectEqual(@as(u2, 2), doc.measure_width('界'));
    }
    try std.testing.expectEqual(parent, doc.root.?);
    try std.testing.expectEqual(sibling, parent.first_child.?);
    try std.testing.expectEqual(@as(?*ui.Node, null), sibling.nextSibling());
}

test "workbench starts contribution and editor factory registries before context keys and parts" {
    const allocator = std.testing.allocator;
    var surface: ui.Surface = undefined;
    try @import("workbench.zig").initWindowSurface(&surface, allocator, 48, 16);
    defer surface.deinit();
    var services = try @import("../vs/workbench/workbench.common.main.zig").createServices(allocator);
    defer services.deinit();
    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    const wb = try Workbench.init(allocator, std.testing.io, @import("./editorView.zig").View.createHandle, &surface, &services, .{}, .{ .registry = &registry });
    defer wb.deinit();
    const Probe = struct {
        window: *Workbench,
        serializer: ImagePreviewEditorInputSerializer,
        stage: usize = 0,

        fn contribution(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(@as(usize, 0), self.stage);
            try std.testing.expectEqual(.Ready, self.window.lifecycle.phase);
            try std.testing.expect(self.window.layout.main_container == null);
            self.stage = 1;
        }

        fn factory(context: *anyopaque, accessor: @import("../vs/platform/instantiation/common/instantiation.zig").ServicesAccessor) !editor_factory.IEditorSerializer {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(@as(usize, 1), self.stage);
            const layout = try accessor.get(@import("../vs/workbench/services/layout/browser/layoutService.zig").layout_service_id);
            try std.testing.expect(layout.getContainer(.editor) == null);
            try std.testing.expect(self.window.context_keys == null);
            self.stage = 2;
            return self.serializer.interface();
        }
    };
    var probe = Probe{ .window = wb, .serializer = ImagePreviewEditorInputSerializer.init(allocator) };
    try wb.contributions.register(.block_restore, &probe, Probe.contribution);
    try registry.registerEditorSerializerFactory(ImagePreviewEditorInput.ID, .{ .context = &probe, .create = Probe.factory });
    try std.testing.expectEqual(@as(usize, 0), probe.stage);
    _ = try wb.startup();
    try std.testing.expectEqual(@as(usize, 2), probe.stage);
    try std.testing.expect(wb.context_keys != null);
    try std.testing.expect(wb.layout.main_container != null);
    try std.testing.expect(wb.core.notification_controller != null);
    try std.testing.expect(wb.part.when_restored.is_open);
    try std.testing.expectEqual(@as(usize, 1), wb.core.restore_state_ready.pending.items.len);
}

test "workbench startup creates the live editor part and applies extraClasses before the first frame" {
    const extra: u16 = 0x00ef;
    const wb_window = try TestWindow.initWithOptions(std.testing.allocator, std.testing.io, &.{}, 80, 24, .{ .extra_classes = &.{extra} }, null);
    const wb = wb_window.workbench;
    defer wb_window.deinit();
    const main = wb.layout.main_container.?;
    try std.testing.expect(main.hasClass(editor_css.workbench.Class.monaco_workbench));
    try std.testing.expect(main.hasClass(extra));
    var child = main.first_child;
    inline for (.{ .activitybar, .sidebar, .editor, .panel, .statusbar }) |id| {
        const container = (try wb.layout.getPart(id)).getContainer().?;
        try std.testing.expectEqual(child, container);
        try std.testing.expect(container.hasClass(@field(editor_css.part.Class, @tagName(id))));
        try std.testing.expectEqualStrings("workbench.parts." ++ @tagName(id), container.getAttribute("id").?);
        child = container.nextSibling();
    }
    try std.testing.expect(child == null);
    for ([_]workbench_layout.Parts{ .activitybar, .sidebar }) |id| {
        const node = (try wb.layout.getPart(id)).getContainer().?;
        try std.testing.expect(node.hasClass(editor_css.part.Class.left));
    }
    try wb.layout.setSideBarPosition(.right);
    const sidebar_node = (try wb.layout.getPart(.sidebar)).getContainer().?;
    try std.testing.expect(sidebar_node.hasClass(editor_css.part.Class.right));
    try std.testing.expect(!sidebar_node.hasClass(editor_css.part.Class.left));
    try wb.layout.setSideBarPosition(.left);
    const status = (try wb.layout.getPart(.statusbar)).getContainer().?;
    try std.testing.expectEqual(.footer, status.asElement().tag);
    try std.testing.expectEqualStrings("status", status.getAttribute("role").?);
    try std.testing.expectEqualStrings("off", status.getAttribute("aria-live").?);
    const part = try wb.layout.getPart(.editor);
    const editor = part.getContainer().?;
    try std.testing.expectEqual(main, editor.parent.?);
    try std.testing.expect(editor.hasClass(editor_css.part.Class.part));
    try std.testing.expect(editor.hasClass(editor_css.part.Class.editor));
    try std.testing.expectEqualStrings("workbench.parts.editor", editor.getAttribute("id").?);
    try std.testing.expectEqualStrings("main", editor.getAttribute("role").?);
    try std.testing.expectEqual(editor, part.content_area.?.parent.?);
    try std.testing.expectEqual(part.content_area.?, wb.part.grid_element.?.parent.?);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderFrame(wb, &out.writer);
    try std.testing.expectEqual(wb.part.grid_element.?, wb.activePane().?.dom.?.split_view.parent.?);
    const tree = wb.editor_surface.box_tree;
    for ([_]workbench_layout.Parts{ .activitybar, .sidebar, .editor, .panel, .statusbar }) |id| {
        const registered = try wb.layout.getPart(id);
        try std.testing.expectEqual(registered.bounds.?, tree.find(registered.getContainer().?).?.rect);
    }
    try std.testing.expectEqual(wb.activePane().?.rect, tree.find(wb.activePane().?.dom.?.split_view).?.rect);
    try wb.resize(95, 30);
    try renderFrame(wb, &out.writer);
    try std.testing.expectEqual(@as(f64, 95), tree.find(main).?.rect.w);
    try std.testing.expectEqual(@as(f64, 30), tree.find(main).?.rect.h);
    try std.testing.expectEqual(part.bounds.?, tree.find(editor).?.rect);
    try std.testing.expectEqual(main, wb.layout.main_container.?);
}

test "resetLayout ignores saved workspace visibility and profile sizes while restoring the editor" {
    const wb_window = try TestWindow.initWithOptions(std.testing.allocator, std.testing.io, &.{}, 80, 24, .{ .reset_layout = true }, null);
    const wb = wb_window.workbench;
    defer wb_window.deinit();
    const before = wb.layout.size(.sidebar);
    try wb.layout.restorePartSizes(.{ .@"workbench.sideBar.size" = before + 10 });
    try std.testing.expectEqual(before, wb.layout.size(.sidebar));
    const visible = wb.layout.isVisible(.sidebar);
    try wb.layout.restoreParts(.{ .@"workbench.sideBar.hidden" = visible, .@"workbench.editor.centered" = true }, &wb.part.when_restored);
    try std.testing.expectEqual(visible, wb.layout.isVisible(.sidebar));
    try std.testing.expect(!wb.layout.isMainEditorCentered());
    try std.testing.expect(wb.layout.isRestored());
}

test "line actions resolve the active code editor when focus leaves it and honor read-only state" {
    const allocator = std.testing.allocator;
    const io = time_compat.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "line-actions.txt", "one");
    defer allocator.free(path);
    const workbench_window = try TestWindow.init(allocator, io, &.{path}, 60, 16);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const tab = workbench.activeTab().?;
    _ = tab.view.setFocused(false);
    try std.testing.expect(workbench.code_editor_api.getFocusedCodeEditor() == null);
    try std.testing.expectEqual(tab.editor, workbench.code_editor_api.getActiveCodeEditor().?);
    try workbench.commands.execute("editor.action.copyLinesDownAction");
    var value = try tab.editor.model.getValue(null, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("one\none", value.items);
    try workbench.commands.execute("editor.action.insertFinalNewLine");
    try std.testing.expectEqual(@as(usize, 3), tab.editor.model.getLineCount());
    tab.editor.setReadOnly(true);
    try workbench.commands.execute("editor.action.copyLinesDownAction");
    try workbench.commands.execute("editor.action.indentLines");
    try std.testing.expectEqual(@as(usize, 3), tab.editor.model.getLineCount());
    var read_only_value = try tab.editor.model.getValue(null, false);
    defer read_only_value.deinit();
    try std.testing.expectEqualStrings("one\none\n", read_only_value.items);
    try workbench.commands.execute("expandLineSelection");
    try std.testing.expect(!tab.editor.modelSelection().isEmpty());
}

test "Workbench: notification center commands render an actionable notification and close it" {
    const allocator = std.testing.allocator;
    const window = try TestWindow.init(allocator, std.testing.io, &.{}, 80, 24);
    defer window.deinit();
    const wb = window.workbench;
    const controller = wb.core.notification_controller.?;
    var count: usize = 0;
    const handle = wb.notification_api.prompt(.Info, .{ .text = "Complete the operation" }, &.{.{ .label = "Complete", .context = &count, .run_fn = struct {
        fn run(ctx: *anyopaque) void {
            const calls: *usize = @ptrCast(@alignCast(ctx));
            calls.* += 1;
        }
    }.run }}, null);
    defer handle.release();
    try wb.commands.execute("notifications.showList");
    try std.testing.expect(controller.center.is_visible);
    try std.testing.expectEqual(true, handle.visible().?);
    try controller.render(window.surface.document(), &wb.frame.next, wb.theme_palette);
    var hit: ?@import("../vs/workbench/browser/parts/notifications/notificationsList.zig").NotificationsList.Hit = null;
    for (controller.list.hits.items) |candidate| if (candidate.action == .primary) {
        hit = candidate;
        break;
    };
    const action = hit orelse return error.MissingNotificationAction;
    try std.testing.expect(controller.handleMouse(&.{ .kind = .down, .button = .left, .x = ui.cell.snap(action.rect.x), .y = ui.cell.snap(action.rect.y) }));
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 0), wb.notification_service.model.notifications.items.len);
    try std.testing.expect(!controller.center.is_visible);
}

test "built-in extension active editor event follows mounted controls without an input pump" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try seedFile(allocator, io, &tmp, "first.txt", "one");
    defer allocator.free(first);
    const second = try seedFile(allocator, io, &tmp, "second.txt", "two");
    defer allocator.free(second);
    const window = try TestWindow.init(allocator, io, &.{}, 80, 24);
    defer window.deinit();
    const wb = window.workbench;
    const State = struct {
        first: []const u8,
        second: []const u8,
        count: usize = 0,
        last: enum { none, first, second, unexpected } = .none,
        fn changed(context: *anyopaque, editor: ?@import("../vs/workbench/api/common/extensionApi.zig").ITextEditor) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.last = if (editor) |value| (if (std.mem.eql(u8, value.path, self.first)) .first else if (std.mem.eql(u8, value.path, self.second)) .second else .unexpected) else .none;
        }
    };
    var state = State{ .first = first, .second = second };
    const registration = try wb.builtin_host.context.editors.onDidChangeActiveEditor(.{ .context = &state, .callback = State.changed });
    defer registration.dispose();
    try wb.openPath(first);
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expect(state.last == .first);
    try wb.openPath(second);
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expect(state.last == .second);
    try wb.activateIndex(0);
    try std.testing.expect(state.last == .first);
    try std.testing.expectEqual(@as(usize, 3), state.count);
}

test "editor and quick input focus events precede the next terminal frame" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try seedFile(allocator, io, &tmp, "first.txt", "one");
    defer allocator.free(first);
    const second = try seedFile(allocator, io, &tmp, "second.txt", "two");
    defer allocator.free(second);
    const window = try TestWindow.init(allocator, io, &.{}, 80, 24);
    defer window.deinit();
    const wb = window.workbench;
    try wb.openPath(first);
    const a = wb.activeTab().?;
    try std.testing.expect(a.view.isFocused());
    try wb.openPath(second);
    const b = wb.activeTab().?;
    try std.testing.expect(!a.view.isFocused());
    try std.testing.expect(b.view.isFocused());
    try wb.activateIndex(0);
    try std.testing.expect(a.view.isFocused());
    try std.testing.expect(!b.view.isFocused());

    try wb.quick_access.showCommandPicker();
    try std.testing.expect(!a.view.isFocused());
    wb.quick_access.controller.hide();
    try std.testing.expect(a.view.isFocused());

    wb.focusStatusBar();
    try std.testing.expect(!a.view.isFocused());
    wb.focusEditor();
    try std.testing.expect(a.view.isFocused());
}

test "HistoryService records active editor changes before a frame and detaches old pane listeners" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_a = try seedFile(allocator, io, &tmp, "history-event-a.txt", "a");
    defer allocator.free(path_a);
    const path_b = try seedFile(allocator, io, &tmp, "history-event-b.txt", "b");
    defer allocator.free(path_b);
    const window = try TestWindow.init(allocator, io, &.{ path_a, path_b }, 60, 15);
    defer window.deinit();
    const workbench = window.workbench;
    try workbench.activateIndex(0);
    const first = workbench.activeTab().?;
    try first.editor.insertText("x");
    try std.testing.expectEqualStrings(first.editor.path, workbench.history.default_stacks.edits.current().?.path);
    try workbench.activateIndex(1);
    const second = workbench.activeTab().?;
    try second.editor.insertText("y");
    try std.testing.expectEqualStrings(second.editor.path, workbench.history.default_stacks.edits.current().?.path);
    try first.editor.insertText("z");
    try std.testing.expectEqualStrings(second.editor.path, workbench.history.default_stacks.edits.current().?.path);
}

test "Git resource actions stage unstage and resolve discard confirmation against the current repository" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    if (!try runGitTest(allocator, root, &.{"init"})) return error.SkipZigTest;
    try std.testing.expect(try runGitTest(allocator, root, &.{ "config", "core.autocrlf", "false" }));
    _ = try runGitTest(allocator, root, &.{ "config", "user.name", "Test User" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try tmp.dir.writeFile(io, .{ .sub_path = "resource.txt", .data = "base\n" });
    if (!try runGitTest(allocator, root, &.{ "add", "resource.txt" })) return error.SkipZigTest;
    if (!try runGitTest(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "initial" })) return error.SkipZigTest;
    try tmp.dir.writeFile(io, .{ .sub_path = "resource.txt", .data = "changed\n" });
    const window = try TestWindow.init(allocator, io, &.{}, 80, 20);
    defer window.deinit();
    const workbench = window.workbench;
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.initGit();
    const provider = workbench.git_model.repository orelse return error.TestExpectedRepository;
    const host = workbench.scm.changes.?.host;
    try std.testing.expectEqual(@as(usize, 1), provider.groups[2].resources.items.len);
    try host.resource_action.?(host.context, .stage, &provider.groups[2].resources.items[0].iface);
    try std.testing.expectEqual(@as(usize, 1), provider.groups[1].resources.items.len);
    try std.testing.expectEqual(@as(usize, 0), provider.groups[2].resources.items.len);
    try host.resource_action.?(host.context, .unstage, &provider.groups[1].resources.items[0].iface);
    try std.testing.expectEqual(@as(usize, 1), provider.groups[2].resources.items.len);
    try host.resource_action.?(host.context, .discard, &provider.groups[2].resources.items[0].iface);
    try std.testing.expect(workbench.isDialogOpen());
    var escape: ui.KeyEvent = .{ .key = .escape };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &escape));
    const unchanged = try tmp.dir.readFileAlloc(io, "resource.txt", allocator, .limited(1024));
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("changed\n", unchanged);
    try host.resource_action.?(host.context, .discard, &provider.groups[2].resources.items[0].iface);
    var left: ui.KeyEvent = .{ .key = .left };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &left));
    var enter: ui.KeyEvent = .{ .key = .enter };
    try std.testing.expect(terminal_workbench.handleDialogKey(workbench, &enter));
    const restored = try tmp.dir.readFileAlloc(io, "resource.txt", allocator, .limited(1024));
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("base\n", restored);
    try std.testing.expectEqual(@as(usize, 0), provider.groups[2].resources.items.len);
}

test "Layout resizePart changes the active group before resizing the editor part" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "resize.txt", "alpha\n");
    defer allocator.free(path);

    const window = try TestWindow.init(allocator, io, &.{path}, 100, 40);
    defer window.deinit();
    const wb = window.workbench;
    try wb.showProblems();
    try wb.splitActive(.horizontal);
    const group = wb.activePane().?;
    const editor_size = wb.layout_api.getSize(.editor);
    const group_size = wb.part.getSize(group);
    const panel_size = wb.layout_api.getSize(.panel);
    try std.testing.expectEqual(wb.layout.main_container, wb.layout_api.getContainer(null));
    try std.testing.expectEqual(wb.part.base.getContainer(), wb.layout_api.getContainer(.editor));

    // A horizontal group sash can absorb the width change without changing
    // the size of the editor part or the neighboring workbench parts.
    try wb.commands.execute("workbench.action.increaseViewWidth");
    try std.testing.expectEqual(group_size.width + 4, wb.part.getSize(group).width);
    try std.testing.expectEqual(editor_size.width, wb.layout_api.getSize(.editor).width);

    // There is no vertical group sash. Grow the editor part instead.
    try wb.commands.execute("workbench.action.decreaseViewHeight");
    try std.testing.expectEqual(editor_size.height - 2, wb.layout_api.getSize(.editor).height);
    try std.testing.expectEqual(panel_size.height + 2, wb.layout_api.getSize(.panel).height);
    try std.testing.expectEqual(group_size.height - 2, wb.part.getSize(group).height);
}

test "Workbench: context keys follow language read-only and search focus events without key dispatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "context-a.txt", "alpha\n");
    defer allocator.free(path);
    const other = try seedFile(allocator, io, &tmp, "context-b.txt", "beta\n");
    defer allocator.free(other);
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    const window = try TestWindow.init(allocator, io, &.{path}, 80, 24);
    defer window.deinit();
    const wb = window.workbench;
    const keys = (try wb.ensureContextKeys()).interface();
    const first = wb.activeTab().?.editor;
    try first.setLanguage("markdown");
    try std.testing.expectEqualStrings("markdown", keys.getContextKeyValue("editorLangId").string);
    first.setReadOnly(true);
    try std.testing.expect(keys.getContextKeyValue("editorReadonly").boolean);
    first.setReadOnly(false);
    try std.testing.expect(!keys.getContextKeyValue("editorReadonly").boolean);

    try wb.openPath(other);
    try std.testing.expectEqualStrings("plaintext", keys.getContextKeyValue("editorLangId").string);
    first.setReadOnly(true);
    try std.testing.expect(!keys.getContextKeyValue("editorReadonly").boolean);
    const second = wb.activeTab().?.editor;
    second.setReadOnly(true);
    try std.testing.expect(keys.getContextKeyValue("editorReadonly").boolean);
    second.setReadOnly(false);

    try wb.initSidebar(root_path);
    _ = try wb.showActivityById("search");
    const search_view = wb.search_window.view.?;
    search_view.focus();
    try std.testing.expect(keys.getContextKeyValue("inputFocus").boolean);
    try std.testing.expect(!keys.getContextKeyValue("listFocus").boolean);
    search_view.focusResults();
    try std.testing.expect(!keys.getContextKeyValue("inputFocus").boolean);
    try std.testing.expect(keys.getContextKeyValue("listFocus").boolean);
}

test "Editor actions resolve the same mounted contribution through getContribution" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "contributions.txt", "alpha beta alpha\n");
    defer allocator.free(path);
    const window = try TestWindow.init(allocator, io, &.{path}, 80, 24);
    defer window.deinit();
    const wb = window.workbench;
    const tab = wb.activeTab().?;
    const Find = @import("../vs/editor/contrib/find/browser/findController.zig").FindController;
    const Sticky = @import("../vs/editor/contrib/stickyScroll/browser/stickyScrollController.zig").StickyScrollController;
    const Words = @import("../vs/editor/contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterContribution;
    try std.testing.expectEqual(tab.controllers.?.find, tab.editor.getContribution(Find).?);
    try std.testing.expectEqual(tab.controllers.?.sticky, tab.editor.getContribution(Sticky).?);
    try std.testing.expectEqual(tab.controllers.?.word_highlighter, tab.editor.getContribution(Words).?);
    const Hover = @import("../vs/editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
    try std.testing.expectEqual(tab.controllers.?.hover, tab.editor.getContribution(Hover).?);
    try wb.commands.execute("actions.find");
    try std.testing.expect(tab.controllers.?.find.state.is_revealed);
}

test "Workbench: configuration events update a mounted markdown preview" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "preview.md", "# Preview");
    defer allocator.free(path);
    const settings = try seedFile(allocator, io, &tmp, "settings.json", "{}");
    defer allocator.free(settings);
    const window = try TestWindow.init(allocator, io, &.{path}, 60, 15);
    defer window.deinit();
    const wb = window.workbench;
    try wb.setUserSettingsPaths(&.{settings});
    const pane = wb.activePane().?;
    try wb.markdown_previews.togglePreview(pane);
    const preview = pane.activeTab().?.markdown_preview.?;
    try std.testing.expect(preview.options.scroll_preview_with_editor);
    try wb.setUserConfigurationValue("markdown.preview.scrollPreviewWithEditor", .{ .bool = false });
    try std.testing.expect(!preview.options.scroll_preview_with_editor);
    try wb.setUserConfigurationValue("markdown.preview.scrollPreviewWithEditor", null);
    try std.testing.expect(preview.options.scroll_preview_with_editor);
}

test "Workbench listens to window focus and dialog visibility through services" {
    const window = try TestWindow.init(std.testing.allocator, std.testing.io, &.{}, 60, 15);
    defer window.deinit();
    const wb = window.workbench;
    const storage = @import("../vs/platform/storage/common/storage.zig");
    const dialogs = @import("../vs/platform/dialogs/common/dialogs.zig");
    const Listener = struct {
        count: usize = 0,
        fn saved(event: storage.IWillSaveStateEvent, self: *@This()) !void {
            try std.testing.expectEqual(storage.WillSaveStateReason.none, event.reason);
            self.count += 1;
        }
        fn confirmed(_: *anyopaque, _: dialogs.IConfirmationResult) void {}
    };
    var listener: Listener = .{};
    const id = try wb.storage_api.on_will_save_state.listen(&listener, Listener.saved);
    defer wb.storage_api.on_will_save_state.unlisten(id);
    const toasts = wb.core.notification_controller.?.toasts;
    try wb.host_service.setFocus(false);
    try std.testing.expect(!toasts.window_focused);
    try std.testing.expectEqual(@as(usize, 1), listener.count);
    // Identical focus reports are not new window transitions.
    try wb.host_service.setFocus(false);
    try std.testing.expectEqual(@as(usize, 1), listener.count);
    try wb.host_service.setFocus(true);
    try std.testing.expect(toasts.window_focused);
    try wb.host_service.setFocus(false);
    try std.testing.expectEqual(@as(usize, 2), listener.count);

    const main = wb.layout.main_container.?;
    const class = editor_css.workbench.Class.modal_dialog_visible;
    try std.testing.expect(!main.hasClass(class));
    const handle = try wb.dialog_api.confirm(.{ .message = "Confirm" }, .{ .context = &listener, .complete = Listener.confirmed });
    try std.testing.expect(main.hasClass(class));
    handle.cancel();
    try std.testing.expect(!main.hasClass(class));
}

test "Search title actions follow query and tree events before painting" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const window = try TestWindow.init(allocator, io, &.{}, 60, 15);
    defer window.deinit();
    const wb = window.workbench;
    try wb.initSidebar(root_buffer[0..root_len]);
    try std.testing.expect(try wb.showActivityById("search"));
    const view = wb.search_window.view.?;
    const commands = @import("../vs/workbench/contrib/search/common/constants.zig").SearchCommandIds;
    const pane = &wb.sidebar_part.pane;
    try std.testing.expectEqualStrings(commands.refresh_search_results, pane.primary_actions.items[0].id);
    try std.testing.expect(!pane.primary_actions.items[0].enabled);
    try view.widget.setValue(.search, "alpha");
    try std.testing.expect(pane.primary_actions.items[0].enabled);
    view.commandViewAsTree(true);
    try std.testing.expectEqualStrings(commands.view_as_list, pane.primary_actions.items[2].id);
    view.commandClear();
    try std.testing.expect(!pane.primary_actions.items[0].enabled);
}

test "Close All and Close Other Editors close the entire selected set but preserve sticky editors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try seedFile(allocator, io, &tmp, "sticky.txt", "one");
    defer allocator.free(first);
    const second = try seedFile(allocator, io, &tmp, "other.txt", "two");
    defer allocator.free(second);
    const third = try seedFile(allocator, io, &tmp, "active.txt", "three");
    defer allocator.free(third);
    const window = try TestWindow.init(allocator, io, &.{ first, second, third }, 60, 15);
    defer window.deinit();
    const wb = window.workbench;
    const pane = wb.activePane().?;
    const sticky = pane.tabs.items[0];
    _ = try pane.group.model.stick(sticky.input);
    try wb.commands.execute("workbench.action.closeOtherEditors");
    try std.testing.expectEqual(@as(usize, 2), wb.tabCount());
    try std.testing.expect(pane.group.model.isSticky(.{ .editor = sticky.input }));
    try wb.openPath(second);
    try std.testing.expectEqual(@as(usize, 3), wb.tabCount());
    try wb.commands.execute("workbench.action.closeAllEditors");
    try std.testing.expectEqual(@as(usize, 1), wb.tabCount());
    try std.testing.expectEqual(sticky, wb.activeTab().?);
    try std.testing.expect(!wb.isDialogOpen());
}

test "Close All Editors confirms all dirty editors together and records one reopen batch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try seedFile(allocator, io, &tmp, "first.txt", "one");
    defer allocator.free(first);
    const second = try seedFile(allocator, io, &tmp, "second.txt", "two");
    defer allocator.free(second);
    const window = try TestWindow.init(allocator, io, &.{ first, second }, 60, 15);
    defer window.deinit();
    const wb = window.workbench;
    for (wb.activePane().?.tabs.items) |tab| try tab.editor.insertText("changed");
    try wb.commands.execute("workbench.action.closeAllEditors");
    try std.testing.expectEqual(@as(usize, 1), wb.dialog_service.model.dialogs.items.len);
    try std.testing.expectEqual(@as(usize, 2), wb.tabCount());
    wb.dialog_service.model.close(2); // Cancel
    try std.testing.expectEqual(@as(usize, 2), wb.tabCount());
    try std.testing.expect(!wb.isDialogOpen());
    try wb.commands.execute("workbench.action.closeAllEditors");
    wb.dialog_service.model.close(1); // Don't Save
    try std.testing.expectEqual(@as(usize, 0), wb.tabCount());
    try std.testing.expect(!wb.isDialogOpen());
    try std.testing.expect(!wb.quit_requested);
    try std.testing.expect(wb.reopenLastClosedEditor());
    try std.testing.expectEqual(@as(usize, 2), wb.tabCount());
}

test "Open Previous and Next Editor traverse groups in grid order and skip empty groups" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try seedFile(allocator, io, &tmp, "a.txt", "a");
    defer allocator.free(a);
    const b = try seedFile(allocator, io, &tmp, "b.txt", "b");
    defer allocator.free(b);
    const c = try seedFile(allocator, io, &tmp, "c.txt", "c");
    defer allocator.free(c);
    const window = try TestWindow.init(allocator, io, &.{ a, b }, 80, 20);
    defer window.deinit();
    const wb = window.workbench;
    const left = wb.activePane().?;
    try wb.activateIndex(1);
    try wb.splitActive(.horizontal);
    const right = wb.activePane().?;
    try wb.openPath(c);
    try wb.activateIndex(0);
    try std.testing.expectEqualStrings("b.txt", wb.activeTab().?.input.getName());
    try wb.commands.execute("workbench.action.previousEditor");
    try std.testing.expectEqual(left, wb.activePane().?);
    try std.testing.expectEqualStrings("b.txt", wb.activeTab().?.input.getName());
    try wb.group_actions.navigateEditor(false);
    try std.testing.expectEqual(right, wb.activePane().?);
    try std.testing.expectEqualStrings("b.txt", wb.activeTab().?.input.getName());

    // Terminal :tabprevious still wraps only inside the active group.
    try wb.switchTab(-1);
    try std.testing.expectEqual(right, wb.activePane().?);
    try std.testing.expectEqualStrings("c.txt", wb.activeTab().?.input.getName());
    const empty = try wb.group_actions.newEmptyGroup(.RIGHT);
    try std.testing.expectEqual(@as(usize, 0), empty.tabs.items.len);
    try wb.commands.execute("workbench.action.previousEditor");
    try std.testing.expectEqual(right, wb.activePane().?);
    try std.testing.expectEqualStrings("c.txt", wb.activeTab().?.input.getName());
    try wb.group_actions.navigateEditor(false);
    try std.testing.expectEqual(left, wb.activePane().?);
    try std.testing.expectEqualStrings("a.txt", wb.activeTab().?.input.getName());
}

test "Editor close event records the actual sequential index for reopen history" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try seedFile(allocator, io, &tmp, "a.txt", "a");
    defer allocator.free(a);
    const b = try seedFile(allocator, io, &tmp, "b.txt", "b");
    defer allocator.free(b);
    const c = try seedFile(allocator, io, &tmp, "c.txt", "c");
    defer allocator.free(c);
    const window = try TestWindow.init(allocator, io, &.{ a, b, c }, 80, 20);
    defer window.deinit();
    const wb = window.workbench;
    const pane = wb.activePane().?;
    const tab = pane.tabs.items[0];
    try std.testing.expectEqualStrings("a.txt", tab.input.getName());
    _ = try pane.group.model.moveEditor(tab.input, 2);
    try pane.activateTab(tab);
    const Event = @import("../vs/workbench/services/editor/common/editorService.zig").IEditorCloseEvent;
    const Observer = struct {
        count: usize = 0,
        index: usize = 0,
        correct_editor: bool = false,
        fn closed(event: Event, self: *@This()) !void {
            self.count += 1;
            self.index = event.index;
            self.correct_editor = std.mem.eql(u8, event.editor.getName(), "a.txt") and event.pinned and !event.sticky;
        }
    };
    var observer: Observer = .{};
    const listener = try wb.editor_api.on_did_close_editor.listen(&observer, Observer.closed);
    defer wb.editor_api.on_did_close_editor.unlisten(listener);
    try wb.commands.execute("workbench.action.closeActiveEditor");
    try std.testing.expectEqual(@as(usize, 1), observer.count);
    try std.testing.expectEqual(@as(usize, 2), observer.index);
    try std.testing.expect(observer.correct_editor);
    const closed = wb.history.closed_editors.items[wb.history.closed_editors.items.len - 1];
    try std.testing.expectEqual(@as(usize, 2), closed.index);
    try std.testing.expect(wb.reopenLastClosedEditor());
    try std.testing.expectEqualStrings("a.txt", pane.group.model.getEditorByIndex(2).?.getName());
}

test "Zen tab actions derive palette preconditions from configuration context events" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try seedFile(allocator, io, &tmp, "sample.txt", "sample");
    defer allocator.free(file);
    const settings = try seedFile(allocator, io, &tmp, "settings.json", "{}");
    defer allocator.free(settings);
    const replacement = try seedFile(allocator, io, &tmp, "replacement.json", "{\"zenMode.showTabs\":\"single\"}");
    defer allocator.free(replacement);
    const window = try TestWindow.init(allocator, io, &.{file}, 80, 20);
    defer window.deinit();
    const wb = window.workbench;
    try wb.setUserSettingsPaths(&.{settings});
    const keys = try wb.ensureContextKeys();
    const config_key = "config.zenMode.showTabs";
    try std.testing.expectEqualStrings("multiple", keys.getValue(config_key).string);
    const zen = @import("../vs/workbench/browser/workbench.zenMode.contribution.zig");
    const menu_id = @import("../vs/platform/actions/common/actions.zig").menu_ids.CommandPalette;
    const hide = wb.commands.menus.getMenuItemPtr(menu_id, zen.zen_hide_editor_tabs_id).?;
    const multiple = wb.commands.menus.getMenuItemPtr(menu_id, zen.zen_show_multiple_editor_tabs_id).?;
    try std.testing.expect(!keys.contextMatchesRules(hide.command.precondition));
    try wb.toggleZenMode(false, false);
    try std.testing.expect(keys.contextMatchesRules(hide.command.precondition));
    try std.testing.expect(!keys.contextMatchesRules(multiple.command.precondition));
    try wb.commands.execute(zen.zen_hide_editor_tabs_id);
    try std.testing.expectEqualStrings("none", keys.getValue(config_key).string);
    try std.testing.expect(!keys.contextMatchesRules(hide.command.precondition));
    try std.testing.expect(keys.contextMatchesRules(multiple.command.precondition));
    try wb.setUserSettingsPaths(&.{replacement});
    try std.testing.expectEqualStrings("single", keys.getValue(config_key).string);
    try std.testing.expect(keys.contextMatchesRules(hide.command.precondition));
}

test "Diff editor commands resolve the active snapshot pane through their service" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "file.txt", "one\ntwo\n");
    defer allocator.free(path);
    const window = try TestWindow.init(allocator, io, &.{}, 100, 20);
    defer window.deinit();
    const wb = window.workbench;
    const settings = try seedFile(allocator, io, &tmp, "settings.json", "{}");
    defer allocator.free(settings);
    try wb.setUserSettingsPaths(&.{settings});
    wb.ensureConfigurationReady();

    try wb.editors.openSnapshotDiff(wb.view_factory, io, null, path, "one\ntwo\n", "ONE\ntwo\nthree\n", "commit-a", "commit-b");
    const tab = wb.activeTab().?;
    const widget = tab.diff.?.widget;
    const count = widget.changeCount();
    try std.testing.expect(count > 0);
    const original_index = widget.current_change orelse count - 1;
    try wb.commands.execute("workbench.action.compareEditor.nextChange");
    try std.testing.expectEqual((original_index + 1) % count, widget.current_change.?);
    try wb.commands.execute("workbench.action.compareEditor.previousChange");
    try std.testing.expectEqual(original_index, widget.current_change.?);
    const next_f5: ui.KeyEvent = .{ .key = .f5, .mods = .{ .alt = true } };
    const previous_f5: ui.KeyEvent = .{ .key = .f5, .mods = .{ .alt = true, .shift = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &next_f5));
    try std.testing.expectEqual((original_index + 1) % count, widget.current_change.?);
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &previous_f5));
    try std.testing.expectEqual(original_index, widget.current_change.?);
    const original = widget.original_editor;
    try std.testing.expect(!widget.inline_mode);
    try wb.commands.execute("workbench.action.compareEditor.swapSides");
    try std.testing.expectEqual(original, widget.modified_editor);
    // Commit labels cannot be re-resolved as Git refs; refresh is a no-op.
    try wb.commands.execute("workbench.action.compareEditor.refreshDiff");
    try std.testing.expectEqual(tab, wb.activeTab().?);
    try wb.commands.execute("workbench.action.compareEditor.focusSecondarySide");
    try std.testing.expectEqual(widget.original_editor, widget.focusedEditor());
    // Each inner editor owns its own find controller, including on read-only snapshots.
    var find_key = ui.KeyEvent{ .key = .{ .char = 'f' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(tab.handleDiffKey(&find_key));
    try std.testing.expect(tab.original_controllers.?.find.isOpen());
    try std.testing.expect(!tab.controllers.?.find.isOpen());
    try tab.original_controllers.?.find.startReplace();
    try std.testing.expect(!tab.original_controllers.?.find.state.is_replace_revealed);
    try wb.commands.execute("workbench.action.compareEditor.focusOtherSide");
    try std.testing.expectEqual(widget.modified_editor, widget.focusedEditor());
    find_key = .{ .key = .{ .char = 'f' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(tab.handleDiffKey(&find_key));
    try std.testing.expect(tab.controllers.?.find.isOpen());
    try wb.commands.execute("diffEditor.setViewMode.inline");
    try std.testing.expect(tab.diff.?.widget.inline_mode);
    try wb.commands.execute("diffEditor.setViewMode.sideBySide");
    try std.testing.expect(tab.diff.?.widget.sideBySide());
    try wb.commands.execute("toggle.diff.ignoreTrimWhitespace");
    try std.testing.expect(!tab.diff.?.widget.options.ignore_trim_whitespace);
    const current = tab.diff.?.widget;
    try wb.commands.execute("diffEditor.switchSide");
    try std.testing.expectEqual(current.original_editor, current.focusedEditor());
    var next_review: ui.KeyEvent = .{ .key = .f7 };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &next_review));
    try std.testing.expect(current.accessible_viewer.visible());
    var review_down: ui.KeyEvent = .{ .key = .down };
    try std.testing.expect(tab.handleDiffKey(&review_down));
    try std.testing.expect(current.accessible_viewer.model.?.current_element_index > 0);
    var review_close: ui.KeyEvent = .{ .key = .escape };
    try std.testing.expect(tab.handleDiffKey(&review_close));
    try std.testing.expect(!current.accessible_viewer.visible());
    try wb.commands.execute("diffEditor.toggleCollapseUnchangedRegions");
    try std.testing.expect(tab.diff.?.widget.options.hide_unchanged_regions);
    try wb.commands.execute("diffEditor.showAllUnchangedRegions");
    try wb.commands.execute("diffEditor.collapseAllUnchangedRegions");

    // Open the focused revision as its own read-only editor over the very
    // same document, using the upstream Ctrl+K, Shift+O chord.
    current.setFocus(.original);
    const original_model = current.originalModel();
    const original_input = tab.diff.?.original_input.interface();
    const chord: ui.KeyEvent = .{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } };
    const open: ui.KeyEvent = .{ .key = .{ .char = 'o' }, .mods = .{ .shift = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &chord));
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &open));
    const resource_tab = wb.activeTab().?;
    try std.testing.expect(!resource_tab.isDiff());
    try std.testing.expect(resource_tab.text_resource_input != null);
    try std.testing.expectEqual(original_input, resource_tab.input);
    try std.testing.expectEqual(original_model, resource_tab.editor.model);
    try std.testing.expect(resource_tab.editor.isReadOnly());
    _ = try wb.closeActive();
    try std.testing.expectEqual(tab, wb.activeTab().?);
    current.setFocus(.modified);
    try wb.commands.execute("workbench.action.compareEditor.openSide");
    try std.testing.expectEqual(current.modifiedModel(), wb.activeTab().?.editor.model);
    try std.testing.expect(wb.activeTab().?.editor.isReadOnly());
}

test "Diff editor commands: CodeLens action uses the active provider context and command picker" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const TextModel = @import("../vs/editor/common/model/textModel.zig").TextModel;
    const Provider = struct {
        runs: usize = 0,
        fn provide(_: *anyopaque, arena: Allocator, _: *TextModel, _: CancellationToken) !?languages.CodeLensList {
            return .{ .lenses = try arena.dupe(languages.CodeLens, &.{.{ .range = Range.init(1, 1, 1, 1), .command = .{ .id = "test.runLens", .title = "Run lens" } }}) };
        }
        fn run(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.runs += 1;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(a, io, &tmp, "lens.txt", "old");
    defer a.free(path);
    const window = try TestWindow.init(a, io, &.{}, 100, 12);
    defer window.deinit();
    const wb = window.workbench;
    try wb.enableLanguageFeatures();
    try wb.editors.openSnapshotDiff(wb.view_factory, io, null, path, "old", "new", "Original", "Modified");
    const tab = wb.activeTab().?;
    const widget = tab.diff.?.widget;
    var options = widget.options;
    options.diff_code_lens = true;
    _ = try widget.updateOptions(options);
    var provider: Provider = .{};
    try wb.commands.registerCommand(.{ .id = "test.runLens", .context = &provider, .run = Provider.run }, .{ .id = "test.runLens", .title = "Run lens" }, .{ .show_in_palette = false });
    defer wb.commands.unregister("test.runLens");
    const registration = try wb.language_features.?.code_lens_provider.register(.{ .language = "*" }, .{ .context = &provider, .provide_code_lenses = Provider.provide });
    var registered = true;
    defer if (registered) registration.dispose();
    for (0..24) |_| _ = wb.window_events.dispatch(std.math.maxInt(i64));
    try std.testing.expect(tab.code_lens.?.enabled);
    try std.testing.expect(tab.editor.has_code_lens_provider);
    const source = wb.commands.source();
    const picks = try source.get_picks(source.context, a);
    defer a.free(picks);
    for (picks) |pick| {
        if (std.mem.eql(u8, pick.command_id, "codelens.showLensesInCurrentLine")) break;
    } else return error.CodeLensCommandMissing;
    try wb.commands.execute("codelens.showLensesInCurrentLine");
    for (0..12) |_| _ = wb.window_events.dispatch(std.math.maxInt(i64));
    try std.testing.expect(wb.quick_access.isPickOpen());
    const picker = wb.quick_access.inputService().pickerRef();
    try std.testing.expectEqualStrings("Run lens", picker.activeItem().?.label);
    picker.accept();
    try std.testing.expectEqual(1, provider.runs);
    registration.dispose();
    registered = false;
    try std.testing.expect(!tab.editor.has_code_lens_provider);
    const after = try source.get_picks(source.context, a);
    defer a.free(after);
    for (after) |pick| try std.testing.expect(!std.mem.eql(u8, pick.command_id, "codelens.showLensesInCurrentLine"));
}

test "Diff editor commands: whitespace hint and timeout prompt use effective configuration" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(a, io, &tmp, "whitespace.txt", "a\n");
    defer a.free(path);
    const settings = try seedFile(a, io, &tmp, "settings.json", "{}");
    defer a.free(settings);
    const window = try TestWindow.init(a, io, &.{}, 120, 28);
    defer window.deinit();
    const wb = window.workbench;
    try wb.setUserSettingsPaths(&.{settings});
    wb.ensureConfigurationReady();
    try wb.editors.openSnapshotDiff(wb.view_factory, io, null, path, "a \n", "a\n", "Original", "Modified");
    const tab = wb.activeTab().?;
    const widget = tab.diff.?.widget;
    try std.testing.expectEqual(@as(usize, 1), widget.contributions.items.len);
    try std.testing.expect(!widget.state().?.identical);
    try std.testing.expectEqual(@as(usize, 0), widget.changeCount());
    var frame: std.Io.Writer.Allocating = .init(a);
    defer frame.deinit();
    try renderFrame(wb, &frame.writer);
    const rendered = try frameText(a, &wb.frame);
    defer a.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Show Whitespace Differences") != null);
    const entries = widget.modified_view.terminal_view_host.viewRef().overlayWidgets().entries.items;
    const hint = for (entries) |entry| {
        if (entry.node.first_child.?.getAttribute("aria-label")) |label| if (std.mem.eql(u8, label, "Show Whitespace Differences")) break entry;
    } else return error.WhitespaceHintMissing;
    var click: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = widget.paneWidths().modifiedLeft() + hint.left + 1, .y = hint.top };
    _ = try tab.handleDiffMouse(&click);
    try std.testing.expect(!widget.options.ignore_trim_whitespace);
    try std.testing.expect(!wb.configuration.?.getBool("diffEditor.ignoreTrimWhitespace", true));
    for (0..5000) |_| {
        if (widget.view_model.is_diff_up_to_date) break;
        const time = @import("../vs/base/common/timeCompat.zig");
        _ = wb.window_events.dispatch(time.milliTimestamp());
        time.sleepMillis(1);
    }
    try std.testing.expect(widget.view_model.is_diff_up_to_date);
    try std.testing.expect(widget.changeCount() > 0);
    try renderFrame(wb, &frame.writer);
    const after = try frameText(a, &wb.frame);
    defer a.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "Show Whitespace Differences") == null);

    try wb.setUserConfigurationValue("diffEditor.maxComputationTime", .{ .integer = 7 });
    try widget.view_model.applyComputedDiff(.{ .identical = false, .quitEarly = true, .changes = &.{}, .moves = &.{} });
    const notification_item = for (wb.notification_service.model.notifications.items) |item| {
        if (item.actions.primary.len != 0 and std.mem.eql(u8, item.actions.primary[0].label(), "Remove Limit")) break item;
    } else return error.DiffTimeoutPromptMissing;
    try std.testing.expectEqual(@import("../vs/base/common/severity.zig").Severity.Warning, notification_item.severity);
    const action = notification_item.actions.primary[0];
    try action.run(action.context, null);
    try std.testing.expectEqual(@as(i64, 0), widget.options.max_computation_time_ms);
    try std.testing.expectEqual(@as(i64, 0), wb.configuration.?.getValue("diffEditor.maxComputationTime", .{}).?.integer);
}

test "Diff editor commands: retained title menu exposes navigation, toggles and view modes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "title.txt", "a\nb\n");
    defer allocator.free(path);
    const settings = try seedFile(allocator, io, &tmp, "settings.json", "{}");
    defer allocator.free(settings);
    const window = try TestWindow.init(allocator, io, &.{}, 100, 25);
    defer window.deinit();
    const wb = window.workbench;
    try wb.setUserSettingsPaths(&.{settings});
    wb.ensureConfigurationReady();
    try wb.editors.openSnapshotDiff(wb.view_factory, io, null, path, "old\na\nb\nc\nd\ne\nf\ng\nlast", "new\na\nb\nc\nd\ne\nf\ng\nLAST", "old", "new");
    const pane = wb.activePane().?;
    const widget = pane.activeTab().?.diff.?.widget;
    var frame: std.Io.Writer.Allocating = .init(allocator);
    defer frame.deinit();
    try renderFrame(wb, &frame.writer);
    try std.testing.expectEqual(@as(usize, 6), pane.toolbar_hits.items.len);
    try std.testing.expectEqualStrings("workbench.action.compareEditor.previousChange", pane.toolbar_hits.items[0].id);
    try std.testing.expectEqualStrings("workbench.action.compareEditor.nextChange", pane.toolbar_hits.items[1].id);
    try std.testing.expect(pane.toolbar_hits.items[1].enabled);
    const before = widget.current_change.?;
    var click: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = pane.toolbar_hits.items[1].start + 1, .y = ui.cell.snap(pane.rect.y) };
    try std.testing.expect(terminal_workbench.handleTabMouse(wb, &click));
    try std.testing.expect(widget.current_change.? != before);
    try std.testing.expectEqualStrings("toggle.diff.ignoreTrimWhitespace", pane.toolbar_hits.items[3].id);
    click.x = pane.toolbar_hits.items[3].start + 1;
    try std.testing.expect(terminal_workbench.handleTabMouse(wb, &click));
    try std.testing.expect(!widget.options.ignore_trim_whitespace);
    try renderFrame(wb, &frame.writer);
    const overflow = pane.toolbar_hits.items[pane.toolbar_hits.items.len - 1];
    try std.testing.expectEqualStrings("editorTitle.overflow", overflow.id);
    click.x = overflow.start + 1;
    try std.testing.expect(terminal_workbench.handleTabMouse(wb, &click));
    const menu = wb.context_menu_service.current.?.popup.?;
    try std.testing.expectEqualStrings("Diff View", menu.items[0].label);
    const modes = menu.items[0].submenu;
    try std.testing.expectEqual(@as(usize, 3), modes.len);
    try std.testing.expectEqualStrings("Inline", modes[0].label);
    try std.testing.expectEqualStrings("Side by Side", modes[1].label);
    try std.testing.expectEqualStrings("Automatic (Currently Side by Side)", modes[2].label);
    try std.testing.expect(modes[2].checked);
    try std.testing.expect(wb.context_menu_service.handleKey(&.{ .key = .home }));
    try std.testing.expect(wb.context_menu_service.handleKey(&.{ .key = .right }));
    try std.testing.expect(wb.context_menu_service.handleKey(&.{ .key = .enter }));
    try std.testing.expect(widget.inline_mode);

    // The inactive group's menu continues to use its own diff context.
    try wb.commands.execute("workbench.action.newGroupRight");
    try wb.openPath(path);
    const file_pane = wb.activePane().?;
    try std.testing.expect(file_pane != pane);
    try renderFrame(wb, &frame.writer);
    try std.testing.expectEqual(@as(usize, 0), file_pane.toolbar_hits.items.len);
    try std.testing.expect(pane.toolbar_hits.items.len > 0);
    click.x = pane.toolbar_hits.items[0].start + 1;
    try std.testing.expect(terminal_workbench.handleTabMouse(wb, &click));
    try std.testing.expectEqual(pane, wb.activePane().?);
}

fn chooseContextMenuItem(wb: *Workbench, label: []const u8) !void {
    const service = &wb.context_menu_service;
    try std.testing.expect(service.handleKey(&.{ .key = .home }));
    const count = service.current.?.items.items.len;
    for (0..count) |_| {
        if (service.current.?.popup.?.focusedItem()) |item| {
            if (std.mem.eql(u8, item.label, label)) {
                try std.testing.expect(service.handleKey(&.{ .key = .enter }));
                return;
            }
        }
        try std.testing.expect(service.handleKey(&.{ .key = .down }));
    }
    return error.TestUnexpectedResult;
}

test "Workbench: editor title context uses picked tab keys and sticky pinning" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try seedFile(allocator, io, &tmp, "pin_a.txt", "a");
    defer allocator.free(a);
    const b = try seedFile(allocator, io, &tmp, "pin_b.txt", "b");
    defer allocator.free(b);
    const window = try TestWindow.init(allocator, io, &.{ a, b }, 60, 12);
    defer window.deinit();
    const wb = window.workbench;
    try wb.activateIndex(1);
    const pane = wb.activePane().?;
    const first = pane.tabAtIndex(allocator, 0).?;
    const second = pane.tabAtIndex(allocator, 1).?;
    const anchor = @import("../vs/platform/contextview/browser/contextMenuService.zig").Anchor{ .x = 1, .y = 1 };
    try wb.editor_tab_menus.onTabContextMenu(pane, first, anchor);
    try chooseContextMenuItem(wb, "Pin");
    try std.testing.expect(pane.group.model.isSticky(.{ .editor = first.input }));
    try std.testing.expect(!pane.group.model.isSticky(.{ .editor = second.input }));
    try wb.editor_tab_menus.onTabContextMenu(pane, second, anchor);
    const rows = wb.context_menu_service.current.?.items.items;
    var found = false;
    for (rows) |row| {
        if (std.mem.eql(u8, row.label, "Close to the Right")) {
            try std.testing.expect(!row.enabled);
            found = true;
        }
    }
    try std.testing.expect(found);
    try chooseContextMenuItem(wb, "Close All");
    try std.testing.expectEqual(@as(usize, 1), wb.tabCount());
    try std.testing.expectEqual(first, wb.activeTab().?);
    try wb.editor_tab_menus.onTabContextMenu(pane, first, anchor);
    try chooseContextMenuItem(wb, "Unpin");
    try std.testing.expect(!pane.group.model.isSticky(.{ .editor = first.input }));
    try std.testing.expect(pane.group.model.isPinned(.{ .editor = first.input }));
}

test "Workbench: group close confirmation veto keeps the entire editor set" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try seedFile(allocator, io, &tmp, "confirm_a.txt", "a");
    defer allocator.free(a);
    const b = try seedFile(allocator, io, &tmp, "confirm_b.txt", "b");
    defer allocator.free(b);
    const c = try seedFile(allocator, io, &tmp, "confirm_c.txt", "c");
    defer allocator.free(c);
    const window = try TestWindow.init(allocator, io, &.{ a, b, c }, 70, 15);
    defer window.deinit();
    const wb = window.workbench;
    for (0..2) |index| {
        try wb.activateIndex(index);
        try wb.activeTab().?.editor.insertText("x");
    }
    try wb.activateIndex(2);
    const pane = wb.activePane().?;
    const anchor = @import("../vs/platform/contextview/browser/contextMenuService.zig").Anchor{ .x = 1, .y = 1 };
    try wb.editor_tab_menus.onTabContextMenu(pane, wb.activeTab().?, anchor);
    try chooseContextMenuItem(wb, "Close All");
    try std.testing.expect(wb.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 3), wb.tabCount());
    var save = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(terminal_workbench.handleDialogKey(wb, &save));
    try std.testing.expect(wb.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 3), wb.tabCount());
    var cancel = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(terminal_workbench.handleDialogKey(wb, &cancel));
    try std.testing.expect(!wb.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 3), wb.tabCount());
    try wb.editor_tab_menus.onTabContextMenu(pane, wb.activeTab().?, anchor);
    try chooseContextMenuItem(wb, "Close All");
    try std.testing.expect(wb.isDialogOpen());
    try std.testing.expect(terminal_workbench.handleDialogKey(wb, &save));
    try std.testing.expect(!wb.isDialogOpen());
    try std.testing.expectEqual(@as(usize, 0), wb.tabCount());
}

test "Workbench: restore remembers hidden composites without opening their views" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const LayoutStorage = @import("layoutStorage.zig").LayoutStorage;
    const OpenEvent = @import("../vs/workbench/browser/parts/paneCompositePart.zig").OpenEvent;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "restore_composites.txt", "one");
    defer allocator.free(path);
    const root = std.fs.path.dirname(path).?;
    {
        const window = try TestWindow.init(allocator, io, &.{path}, 80, 24);
        defer window.deinit();
        const wb = window.workbench;
        try wb.setWorkspaceFolders(&.{root});
        try wb.initSidebarFromWorkspace();
        try std.testing.expect(try wb.showActivityById("search"));
        try std.testing.expect(try wb.openPanelContainer(PROBLEMS_CONTAINER_ID));
        try wb.layout.setPartHidden(true, .sidebar);
        try wb.layout.setPartHidden(true, .panel);
        var storage = try LayoutStorage.init(allocator, io, wb.layout, wb.workspace.getWorkspace().folders.items, root, null);
        defer storage.deinit();
        try LayoutStorage.save(.{ .reason = .quit }, &storage);
    }
    const window = try TestWindow.init(allocator, io, &.{path}, 80, 24);
    defer window.deinit();
    const wb = window.workbench;
    try wb.setWorkspaceFolders(&.{root});
    try wb.initSidebarFromWorkspace();
    const Observer = struct {
        opens: usize = 0,
        fn onOpen(_: OpenEvent, self: *@This()) !void {
            self.opens += 1;
        }
    };
    var observer = Observer{};
    const sidebar_listener = try wb.sidebar_part.pane.on_did_pane_composite_open.listen(&observer, Observer.onOpen);
    defer wb.sidebar_part.pane.on_did_pane_composite_open.unlisten(sidebar_listener);
    const panel_listener = try wb.panel_part.pane.on_did_pane_composite_open.listen(&observer, Observer.onOpen);
    defer wb.panel_part.pane.on_did_pane_composite_open.unlisten(panel_listener);
    {
        var storage = try LayoutStorage.init(allocator, io, wb.layout, wb.workspace.getWorkspace().folders.items, root, null);
        defer storage.deinit();
        const saved = (try storage.load(false)).?;
        try std.testing.expectEqualStrings("search", saved.@"workbench.sidebar.activeviewletid".?);
        try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, saved.@"workbench.panelpart.activepanelid".?);
        try std.testing.expectEqual(@as(usize, 0), observer.opens);
        try wb.layout.restoreParts(saved, &wb.part.when_restored);
        try std.testing.expectEqual(@as(usize, 0), observer.opens);
    }
    try std.testing.expect(!wb.layout.isVisible(.sidebar));
    try std.testing.expect(!wb.layout.isVisible(.panel));
    try std.testing.expect(wb.pane_composite_api.getActivePaneComposite(.sidebar) == null);
    try std.testing.expect(wb.pane_composite_api.getActivePaneComposite(.panel) == null);
    try wb.layout.setPartHidden(false, .sidebar);
    try wb.layout.setPartHidden(false, .panel);
    try std.testing.expectEqualStrings("search", wb.pane_composite_api.getActivePaneComposite(.sidebar).?.id);
    try std.testing.expectEqualStrings(PROBLEMS_CONTAINER_ID, wb.pane_composite_api.getActivePaneComposite(.panel).?.id);
    try std.testing.expectEqual(@as(usize, 2), observer.opens);
}

test "Workbench: status bar navigation uses upstream context-key command registration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "status_focus.txt", "x");
    defer allocator.free(path);
    const window = try TestWindow.init(allocator, io, &.{path}, 80, 12);
    defer window.deinit();
    const wb = window.workbench;
    const context = (try wb.ensureContextKeys()).interface();
    wb.focusEditor();
    try std.testing.expect(!context.getContextKeyValue("statusBarFocused").boolean);
    try std.testing.expect(wb.commands.get("workbench.statusBar.focusFirst") != null);
    try std.testing.expect(!try terminal_workbench.handleGlobalKey(wb, &.{ .key = .home }));
    wb.focusStatusBar();
    try std.testing.expect(context.getContextKeyValue("statusBarFocused").boolean);
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &.{ .key = .end }));
    const last = wb.statusbar.main_part.focusedHandle().?;
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &.{ .key = .home }));
    try std.testing.expect(wb.statusbar.main_part.focusedHandle().? != last);
    // Both the upstream command and the legacy user-binding alias are
    // registered in the same command registry, not a native switch table.
    try wb.commands.execute("workbench.action.statusbar.focusLastEntry");
    try std.testing.expectEqual(last, wb.statusbar.main_part.focusedHandle().?);
    try wb.commands.execute("workbench.statusBar.clearFocus");
    try std.testing.expect(!wb.statusbar.main_part.isEntryFocused());
    try wb.commands.execute("workbench.statusBar.clearFocus");
    try std.testing.expectEqual(Focus.editor, wb.focus);
    try std.testing.expect(!context.getContextKeyValue("statusBarFocused").boolean);
}

fn findPanelTitleActionCell(wb: *Workbench, id: []const u8) ?usize {
    const rect = wb.geometry().panelRect();
    for (panel_part_mod.titleActionsStart(&wb.panel_part, rect)..ui.cell.snap(rect.right())) |x| {
        if (panel_part_mod.hitTitleAction(&wb.panel_part, rect, x, ui.cell.snap(rect.y))) |hit| {
            if (std.mem.eql(u8, hit, id)) return x;
        }
    }
    return null;
}

test "Workbench: panel title menu follows maximization and alignment context events" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(allocator, io, &tmp, "panel_title.txt", "one");
    defer allocator.free(path);
    const window = try TestWindow.init(allocator, io, &.{path}, 80, 24);
    defer window.deinit();
    const wb = window.workbench;
    try std.testing.expect(try wb.openPanelContainer(PROBLEMS_CONTAINER_ID));
    const maximize_id = "workbench.action.toggleMaximizedPanel";
    const close_id = "workbench.action.togglePanel";
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(wb, &out.writer);
    const x = findPanelTitleActionCell(wb, maximize_id) orelse return error.TestUnexpectedResult;
    var click = ui.MouseEvent{ .kind = .down, .button = .left, .x = x, .y = ui.cell.snap(wb.geometry().panelRect().y) };
    try std.testing.expectEqualStrings("Maximize Panel", wb.panel_part.titleActionTooltip(maximize_id).?);
    // The title action must win over the panel sash in the compact border mode.
    try std.testing.expect(terminal_workbench.workbenchSashAt(wb, click.x, click.y) == null);
    try std.testing.expect(terminal_workbench.handlePanelMouse(wb, &click));
    try std.testing.expect(wb.layout.isPanelMaximized());
    try std.testing.expectEqualStrings("Restore Panel", wb.panel_part.titleActionTooltip(maximize_id).?);
    try renderFrame(wb, &out.writer);
    click.x = findPanelTitleActionCell(wb, maximize_id) orelse return error.TestUnexpectedResult;
    click.y = ui.cell.snap(wb.geometry().panelRect().y);
    try std.testing.expect(terminal_workbench.handlePanelMouse(wb, &click));
    try std.testing.expect(!wb.layout.isPanelMaximized());
    try wb.layout.setPanelAlignment(.justify);
    try std.testing.expect(wb.panel_part.titleActionTooltip(maximize_id) == null);
    try renderFrame(wb, &out.writer);
    try std.testing.expect(findPanelTitleActionCell(wb, maximize_id) == null);
    click.x = findPanelTitleActionCell(wb, close_id) orelse return error.TestUnexpectedResult;
    click.y = ui.cell.snap(wb.geometry().panelRect().y);
    try std.testing.expect(terminal_workbench.handlePanelMouse(wb, &click));
    try std.testing.expect(!wb.layout.isVisible(.panel));
}

test "Workbench: git scm integration peek actions stage and revert only the selected change" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    if (!try runGitTest(a, root, &.{"init"})) return error.SkipZigTest;
    try std.testing.expect(try runGitTest(a, root, &.{ "config", "core.autocrlf", "false" }));
    _ = try runGitTest(a, root, &.{ "config", "user.name", "Test User" });
    _ = try runGitTest(a, root, &.{ "config", "user.email", "test@example.com" });
    const original = "one\ntwo\nthree\nfour\nfive\nsix\n";
    const modified = "one\nTWO\nthree\nfour\nfive\nSIX\n";
    const partial = "one\nTWO\nthree\nfour\nfive\nsix\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = original });
    if (!try runGitTest(a, root, &.{ "add", "a.txt" })) return error.SkipZigTest;
    if (!try runGitTest(a, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "initial" })) return error.SkipZigTest;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = modified });
    const path = try std.fs.path.join(a, &.{ root, "a.txt" });
    defer a.free(path);
    const window = try TestWindow.init(a, io, &.{path}, 100, 30);
    defer window.deinit();
    const workbench = window.workbench;
    const settings = try std.fs.path.join(a, &.{ root, ".git", "test-settings.json" });
    defer a.free(settings);
    try workbench.setUserSettingsPaths(&.{settings});
    try workbench.initSidebar(root);
    pumpSidebarForTests(workbench);
    try workbench.initGit();
    const provider = workbench.git_model.repository.?;
    const entry = workbench.scm.quick_diff_controller.?.entries.items[0];
    const primary = provider.quickDiffProviders()[0].id;
    const controller = entry.peek_controller.?;
    const tab = workbench.activeTab().?;
    const Harness = struct {
        fn wait(wb: *Workbench, item: *@import("../vs/workbench/contrib/scm/browser/quickDiffDecorator.zig").Entry, id: []const u8, count: usize) !void {
            for (0..5000) |_| {
                _ = wb.window_events.dispatch(time_compat.milliTimestamp());
                if (item.model.quick_diff_changes.get(id)) |indices| {
                    if (indices.items.len == count) return;
                }
                std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
            }
            return error.TestExpectedQuickDiffChanges;
        }
        fn button(pane: *Tab, peek: *@import("../vs/workbench/contrib/scm/browser/quickDiffWidget.zig").QuickDiffWidget, id: []const u8) !void {
            var child = peek.peek.action_bar.?.first_child;
            const node = while (child) |item| : (child = item.next) {
                if (std.mem.eql(u8, item.getAttribute("data-peek-action") orelse "", id)) break item;
            } else return error.TestExpectedPeekAction;
            const rect = node.kind.element.rect;
            const surface = pane.view.surfaceContext();
            var click: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = ui.cell.snap(rect.x) + 1 - surface.x, .y = ui.cell.snap(rect.y) - surface.y };
            _ = try pane.view.dispatchMouse(&click);
            try std.testing.expect(click.default_prevented);
        }
    };
    try Harness.wait(workbench, entry, primary, 2);
    var frame: std.Io.Writer.Allocating = .init(a);
    defer frame.deinit();
    try renderFrame(workbench, &frame.writer);
    try controller.navigate(true, 2);
    try renderFrame(workbench, &frame.writer);
    try Harness.button(tab, controller.widget.?, "git.stageChange");
    try std.testing.expect(controller.widget == null);
    try std.testing.expectEqual(tab, workbench.activeTab().?);
    const index = (try provider.git.?.readRef(root, "a.txt", .index)).?;
    defer a.free(index);
    try std.testing.expectEqualStrings(partial, index);
    const unchanged = try tmp.dir.readFileAlloc(io, "a.txt", a, .limited(1024));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(modified, unchanged);
    try Harness.wait(workbench, entry, primary, 1);
    try controller.navigate(true, 6);
    try std.testing.expectEqualStrings(primary, controller.widget.?.provider_id);
    try renderFrame(workbench, &frame.writer);
    try Harness.button(tab, controller.widget.?, "git.revertChange");
    try std.testing.expect(controller.widget == null);
    const saved = try tmp.dir.readFileAlloc(io, "a.txt", a, .limited(1024));
    defer a.free(saved);
    try std.testing.expectEqualStrings(partial, saved);
    var contents = try tab.editor.model.getValue(null, false);
    defer contents.deinit();
    try std.testing.expectEqualStrings(partial, contents.items);
    try tab.editor.undo();
    var restored = try tab.editor.model.getValue(null, false);
    defer restored.deinit();
    try std.testing.expectEqualStrings(modified, restored.items);
}

test "Diff editor commands: legacy collapse configuration migrates at Eventually and updates the mounted diff" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(a, io, &tmp, "file.txt", "one\ntwo\nthree\n");
    defer a.free(path);
    const settings = try seedFile(a, io, &tmp, "settings.json", "{\n// retain this comment\n\"diffEditor.experimental.collapseUnchangedRegions\": true,\n}");
    defer a.free(settings);
    const window = try TestWindow.init(a, io, &.{}, 100, 24);
    defer window.deinit();
    const wb = window.workbench;
    try wb.setUserSettingsPaths(&.{settings});
    wb.ensureConfigurationReady();
    try wb.editors.openSnapshotDiff(wb.view_factory, io, null, path, "one\ntwo\nthree\n", "ONE\ntwo\nthree\n", "left", "right");
    const widget = wb.activeTab().?.diff.?.widget;
    try std.testing.expect(!widget.options.hide_unchanged_regions);
    try std.testing.expect(wb.configuration.?.getBool("diffEditor.experimental.collapseUnchangedRegions", false));
    try wb.lifecycle.setPhase(.Eventually);
    try std.testing.expect(wb.configuration_migrations.started);
    try std.testing.expect(widget.options.hide_unchanged_regions);
    try std.testing.expect(wb.configuration.?.getValue("diffEditor.experimental.collapseUnchangedRegions", .{}) == null);
    const saved = try tmp.dir.readFileAlloc(io, "settings.json", a, .limited(1024));
    defer a.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "// retain this comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "diffEditor.hideUnchangedRegions.enabled") != null);
}

test "Diff editor commands: registered accessibility help presents read-only navigation and restores the diff focus" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try seedFile(a, io, &tmp, "file.txt", "one\ntwo\nthree\n");
    defer a.free(path);
    const settings = try seedFile(a, io, &tmp, "settings.json", "{}");
    defer a.free(settings);
    const window = try TestWindow.init(a, io, &.{}, 100, 30);
    defer window.deinit();
    const wb = window.workbench;
    try wb.setUserSettingsPaths(&.{settings});
    wb.ensureConfigurationReady();
    try wb.editors.openSnapshotDiff(wb.view_factory, io, null, path, "one\ntwo\nthree\n", "ONE\ntwo\nthree\n", "left", "right");
    const widget = wb.activeTab().?.diff.?.widget;
    widget.setFocus(.original);
    var frame: std.Io.Writer.Allocating = .init(a);
    defer frame.deinit();
    try renderFrame(wb, &frame.writer);
    try std.testing.expect(widget.options.accessibility_verbose);
    const native_view = @import("editorView.zig").View;
    const original_label = native_view.nativeView(widget.original_view).root_node.?.getAttribute("aria-label").?;
    const modified_label = native_view.nativeView(widget.modified_view).root_node.?.getAttribute("aria-label").?;
    try std.testing.expect(std.mem.indexOf(u8, original_label, "open the accessibility help") != null);
    try std.testing.expectEqualStrings(original_label, modified_label);
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &.{ .key = .f1, .mods = .{ .alt = true } }));
    try std.testing.expect(wb.accessible_view.visible());
    const service = &wb.accessible_view;
    try std.testing.expectEqual(.DiffEditor, service.current.?.provider.id);
    try std.testing.expect(service.current.?.editor.isReadOnly());
    var content = try service.current.?.editor.model.getValue(null, false);
    defer content.deinit();
    try std.testing.expect(std.mem.indexOf(u8, content.items, "You are in a diff editor.") != null);
    try std.testing.expect(std.mem.indexOf(u8, content.items, "F7") != null);
    try std.testing.expect(std.mem.indexOf(u8, content.items, "<keybinding:") == null);
    try std.testing.expect(std.mem.indexOf(u8, content.items, "Disable accessibility verbosity") != null);
    try renderFrame(wb, &frame.writer);
    const painted = try frameText(a, &wb.frame);
    defer a.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Accessibility Help") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "You are in a diff editor.") != null);
    const keys = try wb.ensureContextKeys();
    try std.testing.expect(keys.getValue("accessibilityHelpIsShown").boolean);
    try std.testing.expect(!keys.getValue("editorTextFocus").boolean);
    var select: ui.KeyEvent = .{ .key = .{ .char = 'a' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try service.handleKey(&select));
    var copy: ui.KeyEvent = .{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try service.handleKey(&copy));
    try std.testing.expectEqualStrings(content.items, wb.clipboard_service.text.?);
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &.{ .key = .f6, .mods = .{ .alt = true } }));
    try std.testing.expect(!wb.configuration.?.getBool("accessibility.verbosity.diffEditor", true));
    try std.testing.expect(!widget.options.accessibility_verbose);
    try renderFrame(wb, &frame.writer);
    try std.testing.expectEqualStrings("Editor content", native_view.nativeView(widget.modified_view).root_node.?.getAttribute("aria-label").?);
    try std.testing.expect(!keys.getValue("accessibleViewVerbosityEnabled").boolean);
    var shorter = try service.current.?.editor.model.getValue(null, false);
    defer shorter.deinit();
    try std.testing.expect(std.mem.indexOf(u8, shorter.items, "Disable accessibility verbosity") == null);
    var escape: ui.KeyEvent = .{ .key = .escape };
    try std.testing.expect(try service.handleKey(&escape));
    try std.testing.expect(!service.visible());
    try std.testing.expect(!keys.getValue("accessibilityHelpIsShown").boolean);
    try std.testing.expectEqual(.modified, widget.focused);
    try wb.commands.execute("editor.action.accessibilityHelp");
    try std.testing.expect(service.visible());
    try wb.openPath(path);
    try std.testing.expect(!service.visible());
}

test "Workbench: git scm integration opens Graph Open Changes as a real virtualized multi-diff pane" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    if (!try runGitTest(allocator, root, &.{"init"})) return error.SkipZigTest;
    try std.testing.expect(try runGitTest(allocator, root, &.{ "config", "core.autocrlf", "false" }));
    _ = try runGitTest(allocator, root, &.{ "config", "user.name", "Test User" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "old\nend\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "deleted\n" });
    try std.testing.expect(try runGitTest(allocator, root, &.{ "add", "a.txt", "b.txt" }));
    try std.testing.expect(try runGitTest(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "initial" }));
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "new\nend\n" });
    try tmp.dir.deleteFile(io, "b.txt");
    try tmp.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "added\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "binary.dat", .data = "\x00\x01\x02" });
    try std.testing.expect(try runGitTest(allocator, root, &.{ "add", "-A" }));
    try std.testing.expect(try runGitTest(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "four changes" }));

    const window = try TestWindow.init(allocator, io, &.{}, 120, 25);
    defer window.deinit();
    const wb = window.workbench;
    const settings_path = try std.fs.path.join(allocator, &.{ root, ".git", "test-settings.json" });
    defer allocator.free(settings_path);
    try wb.setUserSettingsPaths(&.{settings_path});
    try wb.initSidebar(root);
    pumpSidebarForTests(wb);
    try wb.initGit();
    try wb.enableLanguageFeatures();
    try wb.setUserConfigurationValue("diffEditor.codeLens", .{ .bool = true });
    const graph = wb.scm.history orelse return error.TestExpectedHistoryView;
    try graph.refresh(.reload);
    graph.config.always_show_actions = true;
    var graph_frame = try ui.Frame.init(allocator, 80, 10);
    defer graph_frame.deinit();
    graph_frame.begin();
    const rect: ui.Rect = .{ .x = 0, .y = 0, .w = 80, .h = 10 };
    try graph.render(&graph_frame.next, rect, true);
    const action = for (graph_frame.next.cluster, 0..) |cp, index| {
        if (cp == scm_history_view_mod.open_changes_glyph) break index;
    } else return error.TestExpectedGraphOpenChangesAction;
    var event: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = action % 80, .y = action / 80 };
    try std.testing.expect(try graph.handleMouse(&event, rect));
    for (0..6000) |_| {
        if (wb.activeTab()) |tab| if (tab.multi_diff) |multi| {
            if (!multi.widget.getViewModel().?.isLoading) break;
        };
        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    const tab = wb.activeTab() orelse return error.TestExpectedMultiDiffTab;
    const multi = tab.multi_diff orelse return error.TestExpectedMultiDiffTab;
    const vm = multi.widget.getViewModel().?;
    try std.testing.expect(!vm.isLoading);
    try std.testing.expectEqual(@as(usize, 4), vm.items.len);
    try std.testing.expectEqual(@as(usize, 4), multi.input.entries.len);
    try std.testing.expect(std.mem.endsWith(u8, multi.input.base.getName(), "(4 files)"));
    try std.testing.expect(!wb.quick_access.isPickOpen());
    var added = false;
    var deleted = false;
    var binary = false;
    var changed = false;
    for (vm.items) |item| {
        if (item.isBinary()) {
            binary = true;
            try std.testing.expect(item.documentDiffItem.modified != null);
        } else if (item.documentDiffItem.original == null) {
            added = true;
            try std.testing.expectEqualStrings("added", try item.modified.model.borrowLineContent(1));
        } else if (item.documentDiffItem.modified == null) {
            deleted = true;
            try std.testing.expectEqualStrings("deleted", try item.original.model.borrowLineContent(1));
        } else {
            changed = true;
            try std.testing.expectEqualStrings("old", try item.original.model.borrowLineContent(1));
            try std.testing.expectEqualStrings("new", try item.modified.model.borrowLineContent(1));
            var resource_arena = std.heap.ArenaAllocator.init(allocator);
            defer resource_arena.deinit();
            try std.testing.expect(!std.mem.eql(u8, try std_uri.query(item.original.model.uri(), resource_arena.allocator()), try std_uri.query(item.modified.model.uri(), resource_arena.allocator())));
        }
    }
    try std.testing.expect(added and deleted and binary and changed);
    try std.testing.expect(multi.widget.activeControl() != null);
    try std.testing.expectEqual(multi.widget.activeControl().?.modified_editor, wb.code_editor_api.getActiveCodeEditor().?);
    const widget = multi.widget.activeControl().?;
    try std.testing.expect(widget.native_input_services != null);
    try std.testing.expect(widget.options.diff_code_lens);
    const Find = @import("../vs/editor/contrib/find/browser/findController.zig").FindController;
    const modified_find = widget.modified_editor.getContribution(Find).?;
    const original_find = widget.original_editor.getContribution(Find).?;
    var find_key: ui.KeyEvent = .{ .key = .{ .char = 'f' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(tab.handleDiffKey(&find_key));
    try std.testing.expect(modified_find.isOpen() and !original_find.isOpen());
    var escape_key: ui.KeyEvent = .{ .key = .escape };
    try std.testing.expect(tab.handleDiffKey(&escape_key));
    try wb.commands.execute("workbench.action.compareEditor.focusSecondarySide");
    try std.testing.expect(tab.handleDiffKey(&find_key));
    try std.testing.expect(original_find.isOpen() and !modified_find.isOpen());
    try std.testing.expect(tab.handleDiffKey(&escape_key));
    try wb.commands.execute("workbench.action.compareEditor.focusPrimarySide");
    const keys_service = try wb.ensureContextKeys();
    try std.testing.expectEqualStrings("multiDiffEditor", keys_service.getValue("activeEditor").string);
    const first_item = vm.activeDiffItem.?;
    const next_key: ui.KeyEvent = .{ .key = .f5, .mods = .{ .alt = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &next_key));
    try std.testing.expect(vm.activeDiffItem.? != first_item);
    const previous_key: ui.KeyEvent = .{ .key = .f5, .mods = .{ .alt = true, .shift = true } };
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &previous_key));
    try std.testing.expectEqual(first_item, vm.activeDiffItem.?);
    try wb.commands.execute("multiDiffEditor.collapseAll");
    try std.testing.expect(multi.widget.impl.allCollapsed());
    try std.testing.expect(keys_service.getValue("multiDiffEditorAllCollapsed").boolean);
    try wb.commands.execute("multiDiffEditor.expandAll");
    try std.testing.expect(!multi.widget.impl.allCollapsed());
    try std.testing.expect(!keys_service.getValue("multiDiffEditorAllCollapsed").boolean);
    try wb.commands.execute("diffEditor.setViewMode.inline");
    try std.testing.expect(multi.widget.activeControl().?.inline_mode);
    try wb.commands.execute("diffEditor.setViewMode.sideBySide");
    try std.testing.expect(multi.widget.activeControl().?.sideBySide());
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try renderFrame(wb, &output.writer);
    const rendered = try frameText(allocator, &wb.frame);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "a.txt") != null);
    try std.testing.expectEqual(@as(usize, 1), wb.tabCount());
    try std.testing.expect(try graph.handleMouse(&event, rect));
    try std.testing.expectEqual(tab, wb.activeTab().?);
    try std.testing.expectEqual(@as(usize, 1), wb.tabCount());
}

test "Workbench: git scm integration opens live Changes group and retains surviving multi-diff documents" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    if (!try runGitTest(allocator, root, &.{"init"})) return error.SkipZigTest;
    try std.testing.expect(try runGitTest(allocator, root, &.{ "config", "core.autocrlf", "false" }));
    _ = try runGitTest(allocator, root, &.{ "config", "user.name", "Test User" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b old\n" });
    try std.testing.expect(try runGitTest(allocator, root, &.{ "add", "a.txt", "b.txt" }));
    try std.testing.expect(try runGitTest(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "initial" }));
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a new\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b new\n" });
    const window = try TestWindow.init(allocator, io, &.{}, 120, 25);
    defer window.deinit();
    const wb = window.workbench;
    const settings_path = try std.fs.path.join(allocator, &.{ root, ".git", "test-settings.json" });
    defer allocator.free(settings_path);
    try wb.setUserSettingsPaths(&.{settings_path});
    try wb.initSidebar(root);
    pumpSidebarForTests(wb);
    try wb.initGit();
    const changes = wb.scm.changes orelse return error.TestExpectedChangesView;
    changes.config.always_show_actions = true;
    var frame = try ui.Frame.init(allocator, 60, 20);
    defer frame.deinit();
    frame.begin();
    const rect: ui.Rect = .{ .x = 0, .y = 0, .w = 60, .h = 20 };
    try changes.render(&frame.next, rect, true, .{});
    const glyph = @import("../vs/workbench/contrib/scm/browser/scmViewPane.zig").SCMViewPane.open_group_changes_glyph;
    const action = for (frame.next.cluster, 0..) |cp, index| {
        if (cp == glyph) break index;
    } else return error.TestExpectedScmGroupAction;
    const b_click = std.mem.indexOf(u32, frame.next.cluster, &.{ 'b', '.', 't', 'x', 't' }) orelse return error.TestExpectedScmResource;
    const a_click = std.mem.indexOf(u32, frame.next.cluster, &.{ 'a', '.', 't', 'x', 't' }) orelse return error.TestExpectedScmResource;
    wb.setFocus(.sidebar);
    var mouse: ui.MouseEvent = .{ .kind = .down, .button = .middle, .x = b_click % 60, .y = b_click / 60 };
    try std.testing.expect(try changes.handleMouse(&mouse, rect));
    try std.testing.expect(wb.activeTab().?.multi_diff.?.input.isResolvingDocuments);
    for (0..6000) |_| {
        if (wb.activeTab()) |tab| if (tab.multi_diff) |multi| {
            if (!multi.widget.getViewModel().?.isLoading and multi.input.entries.len == 2) break;
        };
        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    const tab = wb.activeTab() orelse return error.TestExpectedMultiDiffTab;
    const multi = tab.multi_diff orelse return error.TestExpectedMultiDiffTab;
    try std.testing.expect(multi.input.source_binding != null);
    try std.testing.expect(std.mem.startsWith(u8, multi.input.source_uri, "scm-multi-diff-source:"));
    try std.testing.expectEqual(@as(usize, 2), multi.input.entries.len);
    try std.testing.expect(!multi.input.isResolvingDocuments);
    const initial_vm = multi.widget.getViewModel().?;
    try std.testing.expectEqual(initial_vm.items[1], initial_vm.activeDiffItem.?);
    try std.testing.expectEqual(.sidebar, wb.focus);
    // Reopening an existing source still reveals the explicitly clicked item.
    mouse = .{ .kind = .down, .button = .middle, .x = a_click % 60, .y = a_click / 60 };
    try std.testing.expect(try changes.handleMouse(&mouse, rect));
    try std.testing.expectEqual(tab, wb.activeTab().?);
    try std.testing.expectEqual(initial_vm.items[0], initial_vm.activeDiffItem.?);
    try std.testing.expectEqual(.sidebar, wb.focus);
    // The normal group action follows the same input matching path.
    mouse = .{ .kind = .down, .button = .left, .x = action % 60, .y = action / 60 };
    try std.testing.expect(try changes.handleMouse(&mouse, rect));
    try std.testing.expectEqual(tab, wb.activeTab().?);
    const a_path = try std.fs.path.join(allocator, &.{ root, "a.txt" });
    defer allocator.free(a_path);
    const b_path = try std.fs.path.join(allocator, &.{ root, "b.txt" });
    defer allocator.free(b_path);
    try std.testing.expect(wb.workingCopyService().hasResource(a_path));
    try std.testing.expect(wb.workingCopyService().hasResource(b_path));
    const surviving = multi.input.entries[1].item;
    const b_document = surviving.modified.?.textModel.?;
    try std.testing.expectEqualStrings("b.txt", std.fs.path.basename(b_document.path));
    try std.testing.expectEqualStrings("b new", try b_document.model.borrowLineContent(1));
    try std.testing.expectEqualStrings("b old", try surviving.original.?.textModel.?.model.borrowLineContent(1));
    try std.testing.expect(try runGitTest(allocator, root, &.{ "add", "a.txt" }));
    wb.refreshGitStatus();
    for (0..6000) |_| {
        if (multi.input.entries.len == 1 and !multi.widget.getViewModel().?.isLoading) break;
        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(tab, wb.activeTab().?);
    try std.testing.expectEqual(@as(usize, 1), multi.input.entries.len);
    try std.testing.expectEqual(surviving, multi.input.entries[0].item);
    try std.testing.expectEqual(b_document, multi.input.entries[0].item.modified.?.textModel.?);
    try std.testing.expect(!wb.workingCopyService().hasResource(a_path));
    try std.testing.expect(wb.workingCopyService().hasResource(b_path));
    try wb.commands.execute("git.viewStagedChanges");
    for (0..6000) |_| {
        if (wb.activeTab()) |active| if (active != tab and active.multi_diff != null) {
            if (!active.multi_diff.?.widget.getViewModel().?.isLoading) break;
        };
        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    const staged = (wb.activeTab() orelse return error.TestExpectedMultiDiffTab).multi_diff orelse return error.TestExpectedMultiDiffTab;
    try std.testing.expect(staged != multi);
    try std.testing.expectEqual(@as(usize, 1), staged.input.entries.len);
    try std.testing.expectEqualStrings("a old", try staged.input.entries[0].item.original.?.textModel.?.model.borrowLineContent(1));
    try std.testing.expectEqualStrings("a new", try staged.input.entries[0].item.modified.?.textModel.?.model.borrowLineContent(1));
    try std.testing.expect(staged.input.entries[0].item.options.read_only);
}

test "Workbench: serialize and restore multiple diff resources after the SCM provider activates" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const input_mod = @import("../vs/workbench/contrib/multiDiffEditor/browser/multiDiffEditorInput.zig");
    const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    if (!try runGitTest(allocator, root, &.{"init"})) return error.SkipZigTest;
    try std.testing.expect(try runGitTest(allocator, root, &.{ "config", "core.autocrlf", "false" }));
    _ = try runGitTest(allocator, root, &.{ "config", "user.name", "Test User" });
    _ = try runGitTest(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "old A\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "old B\n" });
    try std.testing.expect(try runGitTest(allocator, root, &.{ "add", "-A" }));
    try std.testing.expect(try runGitTest(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "initial" }));
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "new A\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "new B\n" });

    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    var serializer = input_mod.MultiDiffEditorSerializer.init(allocator);
    try registry.registerEditorSerializer(input_mod.ID, serializer.interface());
    const settings_path = try std.fs.path.join(allocator, &.{ root, ".git", "test-settings.json" });
    defer allocator.free(settings_path);
    const session_path = try std.fs.path.join(allocator, &.{ root, ".git", "multi-session.json" });
    defer allocator.free(session_path);
    const desired_selection = Selection.init(1, 2, 1, 4);
    {
        const window = try TestWindow.init(allocator, io, &.{}, 120, 25);
        defer window.deinit();
        const wb = window.workbench;
        try wb.setUserSettingsPaths(&.{settings_path});
        try wb.initSidebar(root);
        pumpSidebarForTests(wb);
        try wb.initGit();
        try wb.commands.execute("git.viewChanges");
        for (0..6000) |_| {
            if (wb.activeTab()) |tab| if (tab.multi_diff) |multi| {
                if (!multi.widget.getViewModel().?.isLoading) break;
            };
            _ = wb.window_events.dispatch(time_compat.milliTimestamp());
            std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
        }
        const multi = wb.activeTab().?.multi_diff orelse return error.TestExpectedMultiDiffTab;
        const vm = multi.widget.getViewModel().?;
        try std.testing.expectEqual(@as(usize, 2), vm.items.len);
        try vm.items[0].setCollapsed(true);
        const expected_doc = vm.items[1].documentDiffItem;
        try multi.widget.reveal(.{ .original = expected_doc.original.?.uri, .modified = expected_doc.modified.?.uri }, null);
        const control = multi.widget.activeControl() orelse return error.TestExpectedMultiDiffControl;
        try control.modified_editor.setSelections(&.{desired_selection});
        var state = try wb.part.createState(allocator, &registry);
        defer state.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), state.groups[0].editors.len);
        try std.testing.expectEqual(@as(usize, 1), state.editor_view_states.len);
        const session = @import("../vs/workbench/browser/parts/editor/editorSession.zig");
        try session.savePart(allocator, io, session_path, &state);
    }
    // Source metadata is restored but not resolved until the real extension
    // registers its repository. The working text must come from current disk.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "restored new B\n" });
    const session = @import("../vs/workbench/browser/parts/editor/editorSession.zig");
    var loaded = (try session.loadPart(allocator, io, session_path)).?;
    defer loaded.deinit(allocator);
    const restored = try TestWindow.initWithOptions(allocator, io, &.{}, 120, 25, .{}, .{ .data = loaded, .registry = &registry });
    defer restored.deinit();
    const wb = restored.workbench;
    try std.testing.expectEqual(@as(usize, 1), wb.tabCount());
    const tab = wb.activeTab() orelse return error.TestExpectedMultiDiffTab;
    const multi = tab.multi_diff orelse return error.TestExpectedMultiDiffTab;
    try std.testing.expect(multi.widget.getViewModel().?.isLoading);
    try std.testing.expect(multi.input.source_binding != null);
    try wb.setUserSettingsPaths(&.{settings_path});
    try wb.initSidebar(root);
    pumpSidebarForTests(wb);
    try wb.initGit();
    for (0..6000) |_| {
        if (!multi.widget.getViewModel().?.isLoading) break;
        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    const vm = multi.widget.getViewModel().?;
    try std.testing.expect(!vm.isLoading);
    try std.testing.expectEqual(@as(usize, 2), vm.items.len);
    try std.testing.expect(vm.items[0].collapsed);
    try std.testing.expectEqual(vm.items[1], vm.activeDiffItem.?);
    try std.testing.expectEqualStrings("restored new B", try vm.items[1].modified.model.borrowLineContent(1));
    const control = multi.widget.activeControl() orelse return error.TestExpectedMultiDiffControl;
    const selections = try control.modified_editor.getSelections();
    defer allocator.free(selections);
    try std.testing.expectEqualSlices(Selection, &.{desired_selection}, selections);
}

test "Workbench: serialize and restore multiple explicit file resources without an SCM provider" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "left.txt", .data = "left content\n" });
    const left = try tmp.dir.realPathFileAlloc(io, "left.txt", a);
    defer a.free(left);
    const utf16 = try encoding_mod.encode(a, "right content\n", .utf16le_with_bom);
    defer a.free(utf16);
    try tmp.dir.writeFile(io, .{ .sub_path = "right.txt", .data = utf16 });
    const right = try tmp.dir.realPathFileAlloc(io, "right.txt", a);
    defer a.free(right);
    try tmp.dir.writeFile(io, .{ .sub_path = "binary.bin", .data = "\x00\x01\x02" });
    const binary = try tmp.dir.realPathFileAlloc(io, "binary.bin", a);
    defer a.free(binary);
    const window = try TestWindow.init(a, io, &.{left}, 120, 25);
    defer window.deinit();
    const wb = window.workbench;
    const left_tab = wb.activeTab().?;
    try left_tab.editor.setCursorPosition(.init(1, 1));
    try left_tab.editor.insertText("unsaved ");
    const old_document = left_tab.editor.document;
    const source_uri = try std.Uri.parse("multi-diff-editor:explicit-files");
    const left_uri = old_document.model.uri();
    const URI = @import("../vs/base/common/uri.zig").URI;
    var right_file = try URI.file(a, right);
    defer right_file.deinit();
    var binary_file = try URI.file(a, binary);
    defer binary_file.deinit();
    const right_encoded = try right_file.toStringEncoded(a);
    defer a.free(right_encoded);
    const binary_encoded = try binary_file.toStringEncoded(a);
    defer a.free(binary_encoded);
    const right_uri = try std.Uri.parse(right_encoded);
    const binary_uri = try std.Uri.parse(binary_encoded);
    try wb.editor_api.openMultiDiffResources(.{
        .multiDiffSource = source_uri,
        .label = "Explicit files",
        .resources = &.{
            .{ .original = left_uri, .modified = right_uri, .goToFileResource = left_uri },
            .{ .modified = binary_uri },
            .{ .modified = try std.Uri.parse("unavailable:///virtual.txt") },
        },
    });
    for (0..6000) |_| {
        if (wb.activeTab()) |tab| if (tab.multi_diff) |multi| {
            if (!multi.widget.getViewModel().?.isLoading) break;
        };
        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    const tab = wb.activeTab() orelse return error.TestExpectedMultiDiffTab;
    const multi = tab.multi_diff orelse return error.TestExpectedMultiDiffTab;
    const vm = multi.widget.getViewModel().?;
    try std.testing.expectEqual(@as(usize, 2), vm.items.len);
    try std.testing.expectEqualStrings("Explicit files (3 files)", multi.input.base.getName());
    try std.testing.expectEqual(old_document, vm.items[0].original);
    try std.testing.expectEqualStrings("unsaved left content", try vm.items[0].original.model.borrowLineContent(1));
    try std.testing.expectEqualStrings("right content", try vm.items[0].modified.model.borrowLineContent(1));
    try std.testing.expectEqual(encoding_mod.Encoding.utf16le_with_bom, vm.items[0].modified.encoding);
    try std.testing.expect(vm.items[1].isBinary());
    try std.testing.expect(multi.input.last_resolution_failure != null);
    try std.testing.expectEqual(@as(usize, 3), multi.input.initial_resources.?.len);
    try wb.editor_api.openMultiDiffResources(.{ .multiDiffSource = source_uri, .resources = &.{} });
    try std.testing.expectEqual(tab, wb.activeTab().?);
    try std.testing.expectEqual(@as(usize, 2), multi.input.entries.len);
    const control = multi.widget.activeControl() orelse return error.TestExpectedMultiDiffControl;
    const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
    const range = Selection.init(1, 2, 1, 5);
    try control.modified_editor.setSelections(&.{range});
    try wb.commands.execute("multiDiffEditor.goToFile");
    try std.testing.expectEqual(left_tab, wb.activeTab().?);
    const selections = try left_tab.editor.getSelections();
    defer a.free(selections);
    try std.testing.expectEqualSlices(Selection, &.{range}, selections);
}

test "Workbench: serialize and restore multiple diff file list actions share focus and profile state" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "\x00\x02" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/readme.png", .data = "\x00\x01" });
    const config_path = try tmp.dir.realPathFileAlloc(io, "config", a);
    defer a.free(config_path);
    const doc_path = try tmp.dir.realPathFileAlloc(io, "docs/readme.png", a);
    defer a.free(doc_path);
    const missing_path = try std.fs.path.join(a, &.{ config_path, "missing.png" });
    defer a.free(missing_path);
    const URI = @import("../vs/base/common/uri.zig").URI;
    var config_uri = try URI.file(a, config_path);
    defer config_uri.deinit();
    var doc_uri = try URI.file(a, doc_path);
    defer doc_uri.deinit();
    var missing_uri = try URI.file(a, missing_path);
    defer missing_uri.deinit();
    const config_encoded = try config_uri.toStringEncoded(a);
    defer a.free(config_encoded);
    const doc_encoded = try doc_uri.toStringEncoded(a);
    defer a.free(doc_encoded);
    const missing_encoded = try missing_uri.toStringEncoded(a);
    defer a.free(missing_encoded);
    const res: [3]@import("../vs/workbench/common/editor.zig").IMultiDiffEditorResource = .{
        .{ .modified = try std.Uri.parse(config_encoded) },
        .{ .original = try std.Uri.parse(missing_encoded) },
        .{ .modified = try std.Uri.parse(doc_encoded) },
    };
    const window = try TestWindow.init(a, io, &.{}, 120, 25);
    defer window.deinit();
    const wb = window.workbench;
    const settings_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/settings.json", .{tmp.sub_path});
    defer a.free(settings_path);
    try wb.setUserSettingsPaths(&.{settings_path});
    try wb.setUserConfigurationValue("multiDiffEditor.experimental.fileList", .{ .bool = true });
    try wb.commands.execute("multiDiffEditor.viewFileListAsTree");
    try wb.editor_api.openMultiDiffResources(.{ .multiDiffSource = try std.Uri.parse("multi-diff-editor:files-list-first"), .resources = &res });
    for (0..6000) |_| {
        if (wb.activeTab()) |tab| if (tab.multi_diff) |multi| {
            if (!multi.widget.getViewModel().?.isLoading) break;
        };
        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    const first = wb.activeTab().?.multi_diff orelse return error.TestExpectedMultiDiffTab;
    const composite = first.composite orelse return error.TestExpectedFileList;
    const file_list = composite.file_list orelse return error.TestExpectedFileList;
    try std.testing.expect(first.fileListVisible());
    try std.testing.expectEqual(@as(usize, 2), first.input.entries.len);
    try std.testing.expectEqual(@as(usize, 2), file_list.files.len);
    try std.testing.expect(first.input.last_resolution_failure != null);
    try std.testing.expectEqualStrings("readme.png", file_list.files[0].name);
    try std.testing.expectEqualStrings("config", file_list.files[1].name);
    try std.testing.expectEqualStrings("multiDiffEditor", wb.editor_api.activeEditorPane().?.getId());
    const keys = try wb.ensureContextKeys();
    try std.testing.expect(keys.getValue("multiDiffEditorFileListAvailable").boolean);
    try std.testing.expect(keys.getValue("multiDiffEditorFileListVisible").boolean);
    const editor_title = wb.activePane().?.title_control.primaryActions();
    try std.testing.expect(for (editor_title) |action| {
        if (std.mem.eql(u8, action.id(), "multiDiffEditor.toggleFileList")) break true;
    } else false);
    try wb.commands.execute("multiDiffEditor.toggleFileList");
    try std.testing.expect(!first.fileListVisible());
    const source = wb.commands.source();
    const picks = try source.get_picks(source.context, a);
    defer a.free(picks);
    try std.testing.expect(for (picks) |pick| {
        if (std.mem.eql(u8, pick.command_id, "multiDiffEditor.focusFileList")) break true;
    } else false);
    try wb.commands.execute("multiDiffEditor.focusFileList");
    try std.testing.expect(first.fileListVisible() and first.fileListFocused());
    try std.testing.expect(keys.getValue("multiDiffEditorFileListFocus").boolean);
    try std.testing.expect(keys.getValue("listFocus").boolean);
    try std.testing.expect(!keys.getValue("editorTextFocus").boolean);
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &.{ .key = .f1, .mods = .{ .alt = true } }));
    const accessibility = &wb.accessible_view;
    try std.testing.expect(accessibility.visible());
    try std.testing.expectEqual(.MultiDiffEditorFileList, accessibility.current.?.provider.id);
    var help = try accessibility.current.?.editor.model.getValue(null, false);
    defer help.deinit();
    try std.testing.expect(std.mem.indexOf(u8, help.items, "You are in the changed files list of a multi diff editor.") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.items, "Press Enter to reveal the selected file") != null);
    try std.testing.expect(try terminal_workbench.handleGlobalKey(wb, &.{ .key = .f6, .mods = .{ .alt = true } }));
    try std.testing.expect(!wb.configuration.?.getBool("accessibility.verbosity.multiDiffEditorFileList", true));
    var escape: ui.KeyEvent = .{ .key = .escape };
    try std.testing.expect(try accessibility.handleKey(&escape));
    try std.testing.expect(!accessibility.visible());
    try std.testing.expect(first.fileListFocused());
    try wb.commands.execute("multiDiffEditor.positionFileListLeft");
    try std.testing.expectEqual(@as(usize, 0), composite.listX());
    try std.testing.expect(first.fileListFocused());
    try wb.commands.execute("multiDiffEditor.viewFileListAsList");
    try std.testing.expectEqualStrings("config", composite.file_list.?.files[0].name);
    try wb.setUserConfigurationValue("multiDiffEditor.experimental.variant", .{ .string = "cards" });
    try std.testing.expectEqual(@import("../vs/editor/common/multiDiffEditor.zig").MultiDiffEditorVariant.cards, first.widget.impl.variant);
    try std.testing.expect(first.fileListVisible());
    try wb.editor_api.openMultiDiffResources(.{ .multiDiffSource = try std.Uri.parse("multi-diff-editor:files-list-second"), .resources = &res });
    for (0..6000) |_| {
        if (wb.activeTab()) |tab| if (tab.multi_diff) |multi| {
            if (multi != first and !multi.widget.getViewModel().?.isLoading) break;
        };
        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    const second = wb.activeTab().?.multi_diff orelse return error.TestExpectedMultiDiffTab;
    try std.testing.expect(second != first and second.fileListVisible());
    try wb.commands.execute("multiDiffEditor.toggleFileList");
    try std.testing.expect(!first.fileListVisible() and !second.fileListVisible());
}

test "Workbench: serialize and restore multiple diff file list preferences before creating restored panes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{\"multiDiffEditor.experimental.fileList\": true}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "changed.png", .data = "\x00\x01" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const settings_path = try std.fs.path.join(allocator, &.{ root, "settings.json" });
    defer allocator.free(settings_path);
    const profile_path = try std.fs.path.join(allocator, &.{ root, "profile.json" });
    defer allocator.free(profile_path);
    const session_path = try std.fs.path.join(allocator, &.{ root, "session.json" });
    defer allocator.free(session_path);
    const file_path = try std.fs.path.join(allocator, &.{ root, "changed.png" });
    defer allocator.free(file_path);
    var file_uri = try @import("../vs/base/common/uri.zig").URI.file(allocator, file_path);
    defer file_uri.deinit();
    const encoded = try file_uri.toStringEncoded(allocator);
    defer allocator.free(encoded);
    const input_mod = @import("../vs/workbench/contrib/multiDiffEditor/browser/multiDiffEditorInput.zig");
    const registry_mod = @import("../vs/workbench/common/editor/editorFactory.zig");
    const session = @import("../vs/workbench/browser/parts/editor/editorSession.zig");
    const common = @import("../vs/workbench/contrib/multiDiffEditor/common/multiDiffEditor.zig");
    var registry = registry_mod.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    var serializer = input_mod.MultiDiffEditorSerializer.init(allocator);
    try registry.registerEditorSerializer(input_mod.ID, serializer.interface());
    const options: @import("../vs/workbench/browser/workbench.zig").IWorkbenchOptions = .{
        .initial_user_settings_paths = &.{settings_path},
        .profile_storage_path = profile_path,
    };
    {
        const window = try TestWindow.initWithOptions(allocator, io, &.{}, 120, 25, options, null);
        defer window.deinit();
        const wb = window.workbench;
        try wb.editor_api.openMultiDiffResources(.{ .multiDiffSource = try std.Uri.parse("multi-diff-editor:prefs"), .resources = &.{.{ .modified = try std.Uri.parse(encoded) }} });
        const pane = wb.activeTab().?.multi_diff orelse return error.TestExpectedMultiDiffTab;
        try std.testing.expect(pane.fileListVisible());
        try wb.commands.execute("multiDiffEditor.viewFileListAsTree");
        try wb.commands.execute("multiDiffEditor.positionFileListLeft");
        try wb.commands.execute("multiDiffEditor.toggleFileList");
        try wb.storage_api.store(common.FILE_LIST_WIDTH_STORAGE_KEY, .{ .number = 425 }, .profile, .user);
        try wb.storage_api.flush(.shutdown);
        var state = try wb.part.createState(allocator, &registry);
        defer state.deinit(allocator);
        try session.savePart(allocator, io, session_path, &state);
    }
    var restored_state = (try session.loadPart(allocator, io, session_path)).?;
    defer restored_state.deinit(allocator);
    const restored = try TestWindow.initWithOptions(allocator, io, &.{}, 120, 25, options, .{ .data = restored_state, .registry = &registry });
    defer restored.deinit();
    const wb = restored.workbench;
    const pane = wb.activeTab().?.multi_diff orelse return error.TestExpectedMultiDiffTab;
    const composite = pane.composite orelse return error.TestExpectedFileList;
    try std.testing.expect(!pane.fileListVisible());
    try std.testing.expectEqual(common.MultiDiffEditorFileListViewMode.tree, composite.mode);
    try std.testing.expectEqual(common.MultiDiffEditorFileListPosition.left, composite.position);
    try std.testing.expectEqual(@as(usize, 25), composite.preferred_width);
    try wb.commands.execute("multiDiffEditor.focusFileList");
    try std.testing.expect(pane.fileListVisible());
    try std.testing.expect(pane.fileListFocused());
}

test "Workbench: serialize and restore multiple diff layout debug log follows the source until disposal" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "changed.txt", .data = "new text\nsecond line\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "changed.txt", a);
    defer a.free(path);
    var uri = try @import("../vs/base/common/uri.zig").URI.file(a, path);
    defer uri.deinit();
    const encoded = try uri.toStringEncoded(a);
    defer a.free(encoded);
    const window = try TestWindow.init(a, io, &.{}, 120, 25);
    defer window.deinit();
    const wb = window.workbench;
    wb.ensureConfigurationReady();
    try wb.editor_api.openMultiDiffResources(.{ .multiDiffSource = try std.Uri.parse("multi-diff-editor:layout-debug"), .resources = &.{.{ .modified = try std.Uri.parse(encoded) }} });
    const source_group = wb.activePane().?;
    const multi = wb.activeTab().?.multi_diff orelse return error.TestExpectedMultiDiffTab;
    for (0..6000) |_| {
        if (!multi.widget.getViewModel().?.isLoading) break;
        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
        std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    const vm = multi.widget.getViewModel().?;
    try std.testing.expectEqual(@as(usize, 1), vm.items.len);
    try wb.commands.execute("multiDiffEditor.openLayoutDebug");
    const debug_group = wb.activePane().?;
    try std.testing.expect(debug_group != source_group);
    const log = wb.activeTab().?.text_resource_input orelse return error.TestExpectedLayoutDebugInput;
    try std.testing.expectEqualStrings("inmemory", log.document.model.uri().scheme);
    try std.testing.expect(wb.activeTab().?.editor.isReadOnly());
    const initial = try std.json.parseFromSlice(std.json.Value, a, try log.document.model.borrowLineContent(1), .{});
    defer initial.deinit();
    const state = initial.value.object.get("set").?.object;
    try std.testing.expect(state.contains("scrollDimensions"));
    try std.testing.expect(state.contains("layout"));
    try std.testing.expectEqual(@as(usize, 1), state.get("items").?.array.items.len);
    try std.testing.expectEqualStrings("changed.txt", state.get("items").?.array.items[0].object.get("label").?.string);
    const before = log.document.model.getLineCount();
    try vm.items[0].setCollapsed(true);
    try std.testing.expect(log.document.model.getLineCount() > before);
    var contents = try log.document.model.getValue(null, false);
    defer contents.deinit();
    try std.testing.expect(std.mem.indexOf(u8, contents.items, "\"patch\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents.items, "/items/0/collapsed") != null);
    source_group.focus();
    try wb.commands.execute("workbench.action.closeActiveEditor");
    try std.testing.expect(debug_group.activeTab().?.text_resource_input == log);
    debug_group.focus();
    try wb.commands.execute("workbench.action.closeActiveEditor");
}
