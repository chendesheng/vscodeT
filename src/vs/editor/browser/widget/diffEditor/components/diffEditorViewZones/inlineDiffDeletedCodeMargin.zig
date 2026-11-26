// Port of src/vs/editor/browser/widget/diffEditor/components/diffEditorViewZones/inlineDiffDeletedCodeMargin.ts.
// The terminal action sits in the rightmost margin cell of the hovered
// deleted-code row. A native context menu replaces the lightbulb DOM popup.
const std = @import("std");
const ui = @import("ui");
const render_lines = @import("renderLines.zig");
const browser = @import("../../../../editorBrowser.zig");
const TextModel = @import("../../../../../common/model/textModel.zig").TextModel;
const Mapping = @import("../../../../../common/diff/rangeMapping.zig").DetailedLineRangeMapping;
const clipboard_mod = @import("../../../../../../platform/clipboard/common/clipboardService.zig");
const menus = @import("../../../../../../platform/contextview/browser/contextMenuService.zig");

pub const InlineDiffDeletedCodeMargin = struct {
    hovered_row: ?usize = null,

    pub fn render(self: *const InlineDiffDeletedCodeMargin, doc: *ui.Document, info: browser.IViewZone.RenderInfo, render_indicators: bool, color: ui.Color) !*ui.Node {
        const root = try render_lines.renderMargin(doc, info, render_indicators, color);
        errdefer doc.destroy(root);
        const row = self.hovered_row orelse return root;
        if (info.width == 0 or row < info.visible_start_row or row >= (info.visible_end_row orelse info.height)) return root;
        const icon = try doc.createElement(.div);
        icon.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(info.width - 1) },
            .top = .{ .cells = @floatFromInt(row - info.visible_start_row) },
            .width = .{ .cells = 1 },
            .height = .{ .cells = 1 },
            .pointer = .pointer,
            .color = color,
        });
        try icon.setAttribute("aria-label", "Diff actions");
        _ = try icon.appendChild(try doc.createText("◉"));
        _ = try root.appendChild(icon);
        return root;
    }
};

pub const MenuController = struct {
    allocator: std.mem.Allocator,
    clipboard: ?clipboard_mod.IClipboardService = null,
    context_menu: ?menus.IContextMenuService = null,
    open: bool = false,

    pub const RevertTarget = struct {
        context: *anyopaque,
        run: *const fn (*anyopaque, Mapping, u32, u32) anyerror!void,
    };

    const MenuContext = struct {
        owner: *MenuController,
        copy_all: []const u8 = "",
        copy_line: ?[]const u8 = null,
        mapping: Mapping,
        original_version: u32,
        modified_version: u32,
        can_revert: bool,
        revert: RevertTarget,

        fn run(self: *MenuContext, id: []const u8) !void {
            if (std.mem.eql(u8, id, "diff.clipboard.copyDeletedContent")) {
                try self.owner.clipboard.?.writeText(self.copy_all);
            } else if (std.mem.eql(u8, id, "diff.clipboard.copyDeletedLineContent")) {
                if (self.copy_line) |line| try self.owner.clipboard.?.writeText(line);
            } else if (std.mem.eql(u8, id, "diff.inline.revertChange") and self.can_revert) {
                try self.revert.run(self.revert.context, self.mapping, self.original_version, self.modified_version);
            }
        }

        fn onHide(ptr: *anyopaque) void {
            const self: *MenuContext = @ptrCast(@alignCast(ptr));
            self.owner.open = false;
        }
    };

    pub fn attach(self: *MenuController, clipboard: clipboard_mod.IClipboardService, context_menu: menus.IContextMenuService) void {
        self.clipboard = clipboard;
        self.context_menu = context_menu;
    }

    pub fn available(self: *const MenuController) bool {
        return self.clipboard != null and self.context_menu != null;
    }

    pub fn deinit(self: *MenuController) void {
        if (self.open) if (self.context_menu) |service| service.hideContextMenu();
        self.open = false;
    }

    pub fn show(self: *MenuController, original: *TextModel, modified: *TextModel, mapping: Mapping, line: usize, show_revert: bool, can_revert: bool, target: RevertTarget, anchor: menus.Anchor) !bool {
        const service = self.context_menu orelse return false;
        if (self.clipboard == null) return false;
        if (!mapping.original.contains(line) or line > original.getLineCount()) return false;
        const menu = try menus.Menu.init(self.allocator, MenuContext{
            .owner = self,
            .mapping = .{ .original = mapping.original, .modified = mapping.modified, .inner_changes = null },
            .original_version = original.getVersionId(),
            .modified_version = modified.getVersionId(),
            .can_revert = can_revert,
            .revert = target,
        }, MenuContext.run);
        errdefer menu.deinit();
        menu.on_hide = MenuContext.onHide;
        const context = menu.getActionsContext(MenuContext).?;
        const arena = menu.arena.allocator();
        var all = try original.getValueInRange(mapping.original.toExclusiveRange(), null);
        defer all.deinit();
        context.copy_all = try arena.dupe(u8, all.items);
        const deletion = mapping.modified.isEmpty();
        const multiple = mapping.original.length() > 1;
        try menu.add("diff.clipboard.copyDeletedContent", .{
            .label = if (deletion) (if (multiple) "Copy deleted lines" else "Copy deleted line") else (if (multiple) "Copy changed lines" else "Copy changed line"),
        });
        if (multiple) {
            const content = try original.borrowLineContent(line);
            context.copy_line = try arena.dupe(u8, if (content.len == 0) (if (original.getEOL() == .LF) "\n" else "\r\n") else content);
            try menu.add("diff.clipboard.copyDeletedLineContent", .{
                .label = if (deletion) try std.fmt.allocPrint(arena, "Copy deleted line ({d})", .{line}) else try std.fmt.allocPrint(arena, "Copy changed line ({d})", .{line}),
            });
        }
        if (show_revert) try menu.add("diff.inline.revertChange", .{ .label = "Revert this change", .enabled = can_revert });
        try service.showContextMenu(menu, anchor);
        self.open = true;
        return true;
    }
};
