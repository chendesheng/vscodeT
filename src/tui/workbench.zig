//! The multi-file terminal workbench: an editor-part-like shell over the
//! ported `EditorGroupModel`.
//!
//! Layout is the terminal adaptation of the workbench editor part: one tab row
//! at the top, the active editor pane below it. Each tab owns a persistent
//! `View` with its own cell frame; the workbench composites the active view
//! into its frame and encodes one ANSI diff for the whole screen. Switching
//! tabs therefore changes cells, not terminal state, and inactive tabs keep
//! their controllers, decorations and scroll position.
//!
//! A single editor group is ported. Splitting, dragging tabs between groups,
//! tab overflow menus and serialization remain workbench features without a
//! port yet; the group model already supports the single-group behavior.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ui = @import("ui");
const tui = @import("./tui.zig");
const Tab = @import("./tab.zig").Tab;
const Editor = @import("./editor.zig").Editor;
const View = @import("./view.zig").View;
const ViewCell = @import("./view.zig").Cell;
const tab_bar = @import("./tabBar.zig");
const group_mod = @import("../vs/workbench/common/editor/editorGroupModel.zig");

pub const TabKeyResult = enum { unhandled, handled, quit };

pub const Workbench = struct {
    allocator: Allocator,
    io: Io,
    cols: usize,
    rows: usize,

    group: group_mod.EditorGroupModel,
    tabs: std.array_list.Managed(*Tab),
    frame: ui.Frame,
    hits: std.array_list.Managed(tab_bar.Hit),
    is_pasting: bool = false,
    quit_armed: bool = false,

    pub fn init(
        allocator: Allocator,
        io: Io,
        paths: []const []const u8,
        cols: usize,
        rows: usize,
    ) !*Workbench {
        const self = try allocator.create(Workbench);
        errdefer allocator.destroy(self);

        self.* = undefined;
        self.allocator = allocator;
        self.io = io;
        self.cols = @max(cols, 1);
        self.rows = @max(rows, 1);
        self.is_pasting = false;
        self.quit_armed = false;

        self.group = try group_mod.EditorGroupModel.init(allocator, .{});
        self.tabs = std.array_list.Managed(*Tab).init(allocator);
        // Registered in this order so LIFO cleanup disposes the group (and its
        // editor listeners) before the tab inputs are destroyed.
        errdefer {
            for (self.tabs.items) |tab| tab.deinit();
            self.tabs.deinit();
        }
        errdefer self.group.deinit();
        self.frame = try ui.Frame.init(allocator, self.cols, self.rows);
        errdefer self.frame.deinit();
        self.hits = std.array_list.Managed(tab_bar.Hit).init(allocator);

        for (paths, 0..) |path, index| {
            const tab = try Tab.init(
                allocator,
                io,
                path,
                self.cols,
                editorHeight(self.rows),
            );
            // Opening the same resource twice focuses the existing tab, the
            // way the workbench's editor service resolves duplicate inputs.
            if (self.group.findEditor(&tab.input.base, .{})) |existing| {
                tab.deinit();
                if (index == 0) _ = try self.group.setActive(existing.editor);
                continue;
            }

            self.tabs.append(tab) catch |err| {
                tab.deinit();
                return err;
            };
            _ = try self.group.openEditor(&tab.input.base, .{
                .pinned = true,
                .active = index == 0,
            });
        }

        return self;
    }

    pub fn deinit(self: *Workbench) void {
        // Unregister the group's editor listeners before tab inputs (and their
        // emitters) are destroyed.
        self.group.deinit();
        for (self.tabs.items) |tab| tab.deinit();
        self.tabs.deinit();
        self.frame.deinit();
        self.hits.deinit();
        self.allocator.destroy(self);
    }

    fn editorHeight(rows: usize) usize {
        return @max(rows -| 1, 1);
    }

    pub fn activeTab(self: *Workbench) ?*Tab {
        const active = self.group.activeEditor() orelse return null;
        for (self.tabs.items) |tab| {
            if (&tab.input.base == active) return tab;
        }
        return null;
    }

    /// Tabs in sequential (tab strip) order, matching the group model.
    fn orderedTabs(self: *Workbench, out: *std.array_list.Managed(*Tab)) !void {
        const editors = try self.group.getEditors(self.allocator, .SEQUENTIAL, false);
        defer self.allocator.free(editors);
        for (editors) |input| {
            for (self.tabs.items) |tab| {
                if (&tab.input.base == input) {
                    try out.append(tab);
                    break;
                }
            }
        }
    }

    fn activeIndex(self: *Workbench, ordered: []const *Tab) usize {
        const active = self.group.activeEditor() orelse return 0;
        for (ordered, 0..) |tab, index| {
            if (&tab.input.base == active) return index;
        }
        return 0;
    }

    pub fn activateIndex(self: *Workbench, index: usize) !void {
        if (index >= self.tabs.items.len) return;

        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try self.orderedTabs(&ordered);
        if (index >= ordered.items.len) return;

        const tab = ordered.items[index];
        _ = try self.group.setActive(&tab.input.base);
        try tab.ensureControllers();
        tab.view.focusEditor();
        tab.onEditorChanged(@import("../vs/base/common/timeCompat.zig").milliTimestamp());
        try tab.refresh();
    }

    pub fn switchTab(self: *Workbench, delta: isize) !void {
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try self.orderedTabs(&ordered);
        if (ordered.items.len == 0) return;

        const current: isize = @intCast(self.activeIndex(ordered.items));
        const count: isize = @intCast(ordered.items.len);
        const next: isize = @mod(current + delta, count);
        try self.activateIndex(@intCast(next));
    }

    /// Returns true when closing the last tab should quit the workbench.
    pub fn closeActive(self: *Workbench) !bool {
        const tab = self.activeTab() orelse return true;

        if (!tab.editor.requestCloseTab()) return false;

        _ = try self.group.closeEditor(&tab.input.base, .UNKNOWN, true);

        for (self.tabs.items, 0..) |candidate, index| {
            if (candidate == tab) {
                _ = self.tabs.orderedRemove(index);
                break;
            }
        }
        tab.deinit();

        if (self.tabs.items.len == 0) return true;

        if (self.activeTab()) |active| {
            try active.ensureControllers();
        }
        return false;
    }

    pub fn handleTabKey(self: *Workbench, event: *const ui.KeyEvent) !TabKeyResult {
        if (isCtrlChar(event, 'w')) {
            return if (try self.closeActive()) .quit else .handled;
        }

        if (event.mods.ctrl and !event.mods.alt and !event.mods.shift) {
            switch (event.key) {
                .page_up => {
                    try self.switchTab(-1);
                    return .handled;
                },
                .page_down => {
                    try self.switchTab(1);
                    return .handled;
                },
                else => {},
            }
        }

        if (event.mods.alt and !event.mods.ctrl and !event.mods.shift) {
            switch (event.key) {
                .char => |ch| {
                    if (ch >= '1' and ch <= '9') {
                        try self.activateIndex(ch - '1');
                        return .handled;
                    }
                },
                else => {},
            }
        }

        return .unhandled;
    }

    /// Handles mouse input in the tab row. Returns true when the event was
    /// consumed, so the caller does not forward it to the editor at y - 1.
    pub fn hasDirtyTabs(self: *const Workbench) bool {
        for (self.tabs.items) |tab| {
            if (tab.editor.isDirty()) return true;
        }
        return false;
    }

    /// Mirrors the workbench quit prompt for the whole editor part: a dirty
    /// tab arms the first request and the second request quits.
    pub fn requestQuit(self: *Workbench) bool {
        if (!self.hasDirtyTabs()) return true;
        if (self.quit_armed) return true;

        self.quit_armed = true;
        if (self.activeTab()) |tab| {
            tab.editor.setMessage("Unsaved changes: Ctrl-Q again to quit, Ctrl-S to save", .{});
        }
        return false;
    }

    pub fn clearQuitArmed(self: *Workbench) void {
        self.quit_armed = false;
    }

    pub fn handleTabMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
        if (event.y != 0) return false;
        if (event.kind == .down) {
            if (tab_bar.hitAt(self.hits.items, event.x)) |index| {
                self.activateIndex(index) catch {};
            }
        }
        // The whole row belongs to the tab strip; never forward a tab-row
        // event to the editor as view row 0.
        return true;
    }

    pub fn render(self: *Workbench, writer: *std.Io.Writer) !void {
        self.frame.begin();

        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try self.orderedTabs(&ordered);

        const infos = try self.allocator.alloc(tab_bar.TabInfo, ordered.items.len);
        defer self.allocator.free(infos);
        for (ordered.items, 0..) |tab, index| {
            infos[index] = .{
                .label = tab.input.base.getName(),
                .dirty = tab.input.base.isDirty(),
            };
        }

        try tab_bar.draw(
            &self.frame.next,
            infos,
            self.activeIndex(ordered.items),
            0,
            &self.hits,
        );

        if (self.activeTab()) |active| {
            try active.view.paint();
            ui.CellGrid.blit(
                &self.frame.next,
                active.view.grid(),
                0,
                1,
                self.cols,
                self.rows -| 1,
            );
        }

        const encoded = try ui.ansi.encode(
            self.allocator,
            if (self.frame.have_prev) &self.frame.prev else null,
            &self.frame.next,
            .{ .synchronized = true },
        );
        defer self.allocator.free(encoded);
        if (encoded.len > 0) try writer.writeAll(encoded);

        self.frame.swap();
    }

    /// The hardware cursor cell in terminal coordinates, or null when hidden.
    pub fn cursorCell(self: *Workbench) ?ViewCell {
        const active = self.activeTab() orelse return null;
        const cell = active.view.cursorCell() orelse return null;
        const row = cell.row + 1;
        if (row >= self.rows) return null;
        return .{ .row = row, .col = cell.col };
    }

    pub fn resize(self: *Workbench, cols: usize, rows: usize) !void {
        const new_cols = @max(cols, 1);
        const new_rows = @max(rows, 1);
        if (new_cols == self.cols and new_rows == self.rows) {
            for (self.tabs.items) |tab| try tab.refresh();
            return;
        }

        self.cols = new_cols;
        self.rows = new_rows;

        const replacement = try ui.Frame.init(self.allocator, new_cols, new_rows);
        var previous = self.frame;
        self.frame = replacement;
        previous.deinit();

        for (self.tabs.items) |tab| {
            tab.editor.setViewport(new_cols, editorHeight(new_rows));
            try tab.view.resize();
        }
    }

    pub fn syncCursor(self: *Workbench, out: *std.Io.Writer) !void {
        if (self.cursorCell()) |cell| {
            try tui.moveCursor(out, .{ .row = cell.row + 1, .col = cell.col + 1 });
            try tui.showCursor(out);
        } else {
            try tui.hideCursor(out);
        }
    }
};

fn isCtrlChar(event: *const ui.KeyEvent, wanted: u21) bool {
    if (!event.mods.ctrl or event.mods.alt or event.mods.shift) return false;
    return switch (event.key) {
        .char => |ch| ch == wanted,
        else => false,
    };
}

test "Workbench: opens two files, switches tabs and closes them" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/a.txt", .{tmp.sub_path});
    defer allocator.free(path_a);
    const path_b = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/b.txt", .{tmp.sub_path});
    defer allocator.free(path_b);

    var seed_a = try Editor.createFromText(allocator, io, "alpha", path_a, 30, 7);
    try seed_a.save();
    seed_a.deinit();
    allocator.destroy(seed_a);

    var seed_b = try Editor.createFromText(allocator, io, "beta", path_b, 30, 7);
    try seed_b.save();
    seed_b.deinit();
    allocator.destroy(seed_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 30, 8);
    defer workbench.deinit();

    try std.testing.expectEqual(@as(usize, 2), workbench.tabs.items.len);
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.base.getName());

    try workbench.activeTab().?.ensureControllers();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try workbench.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "b.txt") != null);
    try std.testing.expectEqual(@as(usize, 1), workbench.cursorCell().?.row);

    try workbench.activateIndex(1);
    try std.testing.expectEqualStrings("b.txt", workbench.activeTab().?.input.base.getName());

    try workbench.switchTab(-1);
    try std.testing.expectEqualStrings("a.txt", workbench.activeTab().?.input.base.getName());

    const ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabs.items.len);
    try std.testing.expectEqualStrings("b.txt", workbench.activeTab().?.input.base.getName());

    try std.testing.expectEqual(TabKeyResult.quit, try workbench.handleTabKey(&ctrl_w));
}

test "Workbench: dirty tab needs two close requests" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/dirty.txt", .{tmp.sub_path});
    defer allocator.free(path);

    var seed = try Editor.createFromText(allocator, io, "text", path, 30, 7);
    try seed.save();
    seed.deinit();
    allocator.destroy(seed);

    const workbench = try Workbench.init(allocator, io, &.{path}, 30, 8);
    defer workbench.deinit();

    const tab = workbench.activeTab().?;
    try tab.ensureControllers();
    try tab.editor.insertText("!");
    try std.testing.expect(tab.editor.isDirty());

    const ctrl_w = ui.KeyEvent{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(TabKeyResult.handled, try workbench.handleTabKey(&ctrl_w));
    try std.testing.expectEqual(@as(usize, 1), workbench.tabs.items.len);
    try std.testing.expect(tab.editor.isDirty());

    try std.testing.expectEqual(TabKeyResult.quit, try workbench.handleTabKey(&ctrl_w));
}

test "Workbench: duplicate paths focus one tab" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/same.txt", .{tmp.sub_path});
    defer allocator.free(path);

    var seed = try Editor.createFromText(allocator, io, "same", path, 20, 5);
    try seed.save();
    seed.deinit();
    allocator.destroy(seed);

    const workbench = try Workbench.init(allocator, io, &.{ path, path }, 20, 6);
    defer workbench.deinit();

    try std.testing.expectEqual(@as(usize, 1), workbench.tabs.items.len);
    try std.testing.expectEqualStrings("same.txt", workbench.activeTab().?.input.base.getName());
}

test "Workbench: quit is armed while any tab is dirty" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_a = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/clean.txt", .{tmp.sub_path});
    defer allocator.free(path_a);
    const path_b = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/dirty2.txt", .{tmp.sub_path});
    defer allocator.free(path_b);

    var seed_a = try Editor.createFromText(allocator, io, "clean", path_a, 20, 5);
    try seed_a.save();
    seed_a.deinit();
    allocator.destroy(seed_a);
    var seed_b = try Editor.createFromText(allocator, io, "dirty", path_b, 20, 5);
    try seed_b.save();
    seed_b.deinit();
    allocator.destroy(seed_b);

    const workbench = try Workbench.init(allocator, io, &.{ path_a, path_b }, 20, 6);
    defer workbench.deinit();

    try workbench.activateIndex(1);
    try workbench.activeTab().?.editor.insertText("!");

    try std.testing.expect(!workbench.requestQuit());
    try std.testing.expect(workbench.requestQuit());
    workbench.clearQuitArmed();
    try workbench.activeTab().?.editor.save();
    try std.testing.expect(workbench.requestQuit());
}
