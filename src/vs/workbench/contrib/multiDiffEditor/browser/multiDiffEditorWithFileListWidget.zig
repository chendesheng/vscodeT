// Port of `src/vs/workbench/contrib/multiDiffEditor/browser/multiDiffEditorWithFileListWidget.ts`.
// The terminal SplitView uses whole cells (including one sash column), while
// preserving preferred width, responsive visibility, position and focus.
const std = @import("std");
const ui = @import("ui");
const Allocator = std.mem.Allocator;
const common = @import("../common/multiDiffEditor.zig");
const widget_mod = @import("../../../../editor/browser/widget/multiDiffEditor/multiDiffEditorWidget.zig");
const vm_mod = @import("../../../../editor/browser/widget/multiDiffEditor/multiDiffEditorViewModel.zig");
const file_list_mod = @import("multiDiffEditorFileList.zig");
const storage = @import("../../../../platform/storage/common/storage.zig");
const list_service = @import("../../../../platform/list/browser/listService.zig");
const Workspace = @import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const event = @import("../../../../base/common/event.zig");
const split = @import("../../../../base/browser/ui/splitview/splitview.zig");
const layout = @import("../../../services/layout/browser/layoutService.zig");
const ThemeColors = @import("../../../browser/themeColors.zig").ThemeColors;
const time = @import("../../../../base/common/timeCompat.zig");

pub fn MultiDiffEditorWithFileListWidget(comptime View: type) type {
    return struct {
        const Self = @This();
        pub const Widget = widget_mod.MultiDiffEditorWidget(View);
        pub const FileList = file_list_mod.MultiDiffEditorFileList(View);
        pub const DEFAULT_FILE_LIST_WIDTH = layout.widthInCells(260);
        pub const MIN_FILE_LIST_WIDTH = layout.widthInCells(160);
        pub const MIN_DIFF_EDITOR_WIDTH = layout.widthInCells(400);
        const sash_width = 1;
        pub const FILE_LIST_WIDTH_STORAGE_KEY = common.FILE_LIST_WIDTH_STORAGE_KEY;

        allocator: Allocator,
        widget: *Widget,
        file_list: ?*FileList = null,
        storage_service: storage.IStorageService,
        workspace: ?*Workspace,
        lists: ?*list_service.ListService,
        mode: common.MultiDiffEditorFileListViewMode,
        position: common.MultiDiffEditorFileListPosition,
        enabled: bool,
        isFileListVisible: bool = false,
        preferred_width: usize,
        width: usize = 0,
        height: usize = 0,
        origin_x: usize = 0,
        origin_y: usize = 0,
        current_list_width: usize = 0,
        focused_target: enum { diff, files } = .diff,
        pane_focused: bool = false,
        theme: ?*const ThemeColors = null,
        drag: ?split.SashDragState = null,
        last_sash_click: ?i64 = null,
        changed: event.Emitter(void),

        pub fn create(allocator: Allocator, io: std.Io, queue: *dispatch.Queue, host: Widget.Host, variant: common.MultiDiffEditorVariant, store: storage.IStorageService, workspace: ?*Workspace, lists: ?*list_service.ListService, enabled: bool, mode: common.MultiDiffEditorFileListViewMode, position: common.MultiDiffEditorFileListPosition) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const widget = try Widget.create(allocator, io, queue, host, variant);
            errdefer widget.destroy();
            const preferred = if (store.get(FILE_LIST_WIDTH_STORAGE_KEY, .profile, null)) |value| blk: {
                const px = std.fmt.parseInt(usize, value, 10) catch 260;
                break :blk @max(MIN_FILE_LIST_WIDTH, layout.widthInCells(px));
            } else DEFAULT_FILE_LIST_WIDTH;
            self.* = .{
                .allocator = allocator,
                .widget = widget,
                .storage_service = store,
                .workspace = workspace,
                .lists = lists,
                .mode = mode,
                .position = position,
                .enabled = enabled,
                .preferred_width = preferred,
                .changed = event.Emitter(void).init(allocator),
            };
            errdefer {
                self.detachFileList();
                self.changed.deinit();
            }
            try self.updateFileList();
            return self;
        }
        pub fn destroy(self: *Self) void {
            self.detachFileList();
            self.widget.destroy();
            self.changed.deinit();
            self.allocator.destroy(self);
        }
        pub fn detachFileList(self: *Self) void {
            if (self.file_list) |list| list.destroy();
            self.file_list = null;
            self.isFileListVisible = false;
            self.focused_target = .diff;
        }
        fn updateFileList(self: *Self) !void {
            if (!self.enabled) {
                const was_focused = self.focused_target == .files;
                self.detachFileList();
                if (was_focused and self.pane_focused) try self.widget.setFocused(true);
            } else if (self.file_list == null) {
                self.file_list = try FileList.create(self.allocator, self.widget, self.workspace, self.lists, .{ .context = self, .focus_diff = focusDiffCallback }, self.mode);
                self.file_list.?.theme = self.theme;
            }
        }
        pub fn setViewModel(self: *Self, value: ?*vm_mod.MultiDiffEditorViewModel, preserve_focus: bool) !void {
            try self.widget.setViewModel(value, .{ .preserveFocus = preserve_focus });
            if (self.file_list) |list| try list.setModel(value);
        }
        pub fn setWorkspace(self: *Self, workspace: ?*Workspace) !void {
            self.workspace = workspace;
            if (self.file_list) |list| try list.setWorkspace(workspace);
        }
        pub fn setPreferences(self: *Self, enabled: bool, mode: common.MultiDiffEditorFileListViewMode, position: common.MultiDiffEditorFileListPosition) !void {
            const changed = self.enabled != enabled or self.mode != mode or self.position != position;
            self.enabled = enabled;
            self.mode = mode;
            self.position = position;
            try self.updateFileList();
            if (self.file_list) |list| try list.setMode(mode);
            try self.layoutWidget(self.width, self.height);
            if (changed) try self.changed.fire({});
        }
        pub fn layoutWidget(self: *Self, width: usize, height: usize) !void {
            self.width = width;
            self.height = height;
            const visible = self.enabled and width >= MIN_DIFF_EDITOR_WIDTH + MIN_FILE_LIST_WIDTH + sash_width;
            const visibility_changed = self.isFileListVisible != visible;
            self.isFileListVisible = visible;
            self.current_list_width = if (visible) std.math.clamp(self.preferred_width, MIN_FILE_LIST_WIDTH, width - MIN_DIFF_EDITOR_WIDTH - sash_width) else 0;
            if (!visible and self.focused_target == .files) self.focusDiff() catch {};
            try self.widget.layout(self.diffWidth(), height);
            if (visibility_changed) try self.changed.fire({});
        }
        pub fn diffWidth(self: *const Self) usize {
            return self.width -| self.current_list_width -| @as(usize, if (self.isFileListVisible) sash_width else 0);
        }
        pub fn diffX(self: *const Self) usize {
            return if (self.isFileListVisible and self.position == .left) self.current_list_width + sash_width else 0;
        }
        pub fn listX(self: *const Self) usize {
            return if (self.position == .left) 0 else self.diffWidth() + sash_width;
        }
        fn sashX(self: *const Self) usize {
            return if (self.position == .left) self.current_list_width else self.diffWidth();
        }
        pub fn setThemeColors(self: *Self, palette: ?*const ThemeColors) void {
            self.theme = palette;
            self.widget.impl.setThemeColors(palette) catch {};
            if (self.file_list) |list| list.theme = palette;
        }
        pub fn paint(self: *Self, frame: *ui.Frame, x: usize, y: usize, width: usize, height: usize) !void {
            if (width != self.width or height != self.height) try self.layoutWidget(width, height);
            self.origin_x = x;
            self.origin_y = y;
            try self.widget.paint(frame, x + self.diffX(), y, self.diffWidth(), height);
            if (self.isFileListVisible) if (self.file_list) |list| {
                list.render(&frame.next, .{ .x = @floatFromInt(x + self.listX()), .y = @floatFromInt(y), .w = @floatFromInt(self.current_list_width), .h = @floatFromInt(height) });
                const border = if (self.theme) |palette| palette.color("multiDiffEditor.border", .{ 69, 69, 69 }) else ui.Color{ .r = 69, .g = 69, .b = 69 };
                for (0..height) |row| frame.next.putCodepoint(x + self.sashX(), y + row, '│', 1, .{ .fg = ui.cell.packColor(border) });
            };
        }
        pub fn focusFileList(self: *Self) !void {
            if (!self.isFileListVisible) return;
            const list = self.file_list orelse return;
            const changed = self.focused_target != .files or !self.pane_focused;
            self.pane_focused = true;
            self.focused_target = .files;
            try self.widget.setFocused(false);
            list.focus(true);
            if (changed) try self.changed.fire({});
        }
        fn focusDiffCallback(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.focusDiff() catch {};
        }
        pub fn focusDiff(self: *Self) !void {
            const was_list = self.focused_target == .files;
            if (self.file_list) |list| list.focus(false);
            self.focused_target = .diff;
            try self.widget.setFocused(self.pane_focused);
            if (was_list) try self.changed.fire({});
        }
        pub fn setFocused(self: *Self, focused: bool) !void {
            if (self.pane_focused == focused) return;
            self.pane_focused = focused;
            if (self.file_list) |list| list.focus(focused and self.focused_target == .files and self.isFileListVisible);
            try self.widget.setFocused(focused and self.focused_target == .diff);
            try self.changed.fire({});
        }
        pub fn isFileListFocused(self: *const Self) bool {
            return self.pane_focused and self.isFileListVisible and self.focused_target == .files;
        }
        pub fn cursorCell(self: *Self) ?struct { row: usize, col: usize } {
            if (self.isFileListFocused()) return null;
            const cell = self.widget.cursorCell() orelse return null;
            return .{ .row = cell.row, .col = cell.col + self.diffX() };
        }
        pub fn pointerAt(self: *Self, x: usize, y: usize) !ui.Pointer {
            if (self.isFileListVisible) {
                if (x == self.sashX() or self.drag != null) return .ew_resize;
                if (x >= self.listX() and x < self.listX() + self.current_list_width) return .default;
            }
            return self.widget.pointerAt(x -| self.diffX(), y);
        }
        pub fn focusTabEdge(self: *Self, direction: ui.dom.FocusDirection) !bool {
            if (self.isFileListVisible and ((direction == .forward) == (self.position == .left))) {
                try self.focusFileList();
                return true;
            }
            try self.focusDiff();
            return self.widget.focusTabEdge(direction);
        }
        pub fn dispatchTabFocus(self: *Self, input: *ui.KeyEvent, direction: ui.dom.FocusDirection) !bool {
            const list_after_diff = (direction == .forward) == (self.position == .right);
            if (self.isFileListFocused()) {
                if (list_after_diff) return false;
                try self.focusDiff();
                return self.widget.focusTabEdge(direction);
            }
            if (try self.widget.dispatchTabFocus(input, direction)) return true;
            if (!self.isFileListVisible or !list_after_diff) return false;
            try self.focusFileList();
            return true;
        }
        pub fn dispatchKey(self: *Self, input: *ui.KeyEvent) !bool {
            if (self.isFileListFocused()) {
                if (input.key == .escape) {
                    try self.focusDiff();
                    return true;
                }
                if (self.file_list) |list| return list.handleKey(input);
            }
            return self.widget.dispatchKey(input);
        }
        fn viewSizes(self: *Self) [2]split.ViewSize {
            const diff: split.ViewSize = .{ .size = self.diffWidth(), .minimum = MIN_DIFF_EDITOR_WIDTH, .maximum = self.width };
            const files: split.ViewSize = .{ .size = self.current_list_width, .minimum = MIN_FILE_LIST_WIDTH, .maximum = self.width };
            return if (self.position == .left) .{ files, diff } else .{ diff, files };
        }
        fn finishDrag(self: *Self) !void {
            self.drag = null;
            try self.storage_service.store(FILE_LIST_WIDTH_STORAGE_KEY, .{ .number = @floatFromInt(self.preferred_width * 17) }, .profile, .user);
        }
        pub fn dispatchMouse(self: *Self, input: *ui.MouseEvent) !bool {
            if (self.drag) |drag| {
                switch (input.kind) {
                    .move => {
                        const sizes = drag.onSashChange(input.x, self.viewSizes());
                        self.preferred_width = sizes[if (self.position == .left) 0 else 1];
                        try self.layoutWidget(self.width, self.height);
                        return true;
                    },
                    .up => {
                        try self.finishDrag();
                        return true;
                    },
                    else => {},
                }
            }
            if (self.isFileListVisible) {
                if (input.x == self.sashX() and input.kind == .down and input.button == .left) {
                    const now = time.milliTimestamp();
                    if (self.last_sash_click) |previous| if (now - previous <= 300) {
                        self.drag = null;
                        self.last_sash_click = null;
                        self.preferred_width = DEFAULT_FILE_LIST_WIDTH;
                        self.storage_service.remove(FILE_LIST_WIDTH_STORAGE_KEY, .profile);
                        try self.layoutWidget(self.width, self.height);
                        return true;
                    };
                    self.last_sash_click = now;
                    self.drag = split.SashDragState.onSashStart(input.x, self.viewSizes());
                    return true;
                }
                if (input.x >= self.listX() and input.x < self.listX() + self.current_list_width) {
                    if (input.kind == .down and input.button == .left) try self.focusFileList();
                    if (self.file_list) |list| {
                        var translated = input.*;
                        translated.x += self.origin_x;
                        translated.y += self.origin_y;
                        return list.handleMouse(&translated);
                    }
                    return false;
                }
            }
            if (self.file_list) |list| if (input.kind == .move) list.tree.clearHover();
            if (input.kind == .down) {
                self.pane_focused = true;
                try self.focusDiff();
            }
            var translated = input.*;
            translated.x -|= self.diffX();
            return self.widget.dispatchMouse(&translated);
        }
    };
}
