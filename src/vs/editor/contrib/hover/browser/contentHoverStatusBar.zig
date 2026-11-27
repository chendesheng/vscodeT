// Port of `src/vs/editor/contrib/hover/browser/contentHoverStatusBar.ts`.
//
// Terminal adaptation: the status bar is a single row of `[Label]` actions at
// the bottom of the hover, wrapping at cell boundaries when its width is
// constrained. Actions are native focusable pointer/keyboard controls; a
// status message represents the upstream transient placeholder element.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const ui = @import("ui");
const hoverTypes = @import("./hoverTypes.zig");
const HoverActionOptions = hoverTypes.HoverActionOptions;
const IEditorHoverAction = hoverTypes.IEditorHoverAction;
const IEditorHoverStatusBar = hoverTypes.IEditorHoverStatusBar;

const background = ui.Color{ .r = 48, .g = 48, .b = 56 };
const foreground = ui.Color{ .r = 225, .g = 225, .b = 225 };
const action_color = ui.Color{ .r = 120, .g = 180, .b = 255 };
const textWidth = @import("../../../common/markdown/markdownTerminalRenderer.zig").textWidth;

const Action = struct {
    label: []const u8,
    command_id: []const u8,
    run: ?*const fn (context: ?*anyopaque) void,
    run_context: ?*anyopaque,
    run_at: ?*const fn (?*anyopaque, *ui.Node) void,
    enabled: bool = true,
};

const ActionHandle = struct {
    bar: *EditorHoverStatusBar,
    index: usize,
};

pub const EditorHoverStatusBar = struct {
    allocator: Allocator,
    actions: ArrayList(Action),
    handles: ArrayList(*ActionHandle),
    content_nodes: usize = 0,
    message: ?[]u8 = null,
    node: ?*ui.Node = null,

    pub fn init(allocator: Allocator) EditorHoverStatusBar {
        return .{
            .allocator = allocator,
            .actions = ArrayList(Action).init(allocator),
            .handles = ArrayList(*ActionHandle).init(allocator),
        };
    }

    pub fn deinit(self: *EditorHoverStatusBar) void {
        for (self.actions.items) |action| {
            self.allocator.free(action.label);
            self.allocator.free(action.command_id);
        }
        for (self.handles.items) |handle| self.allocator.destroy(handle);
        self.handles.deinit();
        self.actions.deinit();
        if (self.message) |message| self.allocator.free(message);
    }

    pub fn interface(self: *EditorHoverStatusBar) IEditorHoverStatusBar {
        return .{
            .context = self,
            .add_action = addAction,
            .has_content = hasContentCallback,
            .append = append,
            .set_message = setMessage,
        };
    }

    pub fn hasContent(self: *const EditorHoverStatusBar) bool {
        return self.actions.items.len > 0 or self.content_nodes > 0 or self.message != null;
    }

    fn setMessage(context: *anyopaque, message: ?[]const u8) void {
        const self: *EditorHoverStatusBar = @ptrCast(@alignCast(context));
        const owned = if (message) |value| self.allocator.dupe(u8, value) catch return else null;
        if (self.message) |old| self.allocator.free(old);
        self.message = owned;
    }

    fn addAction(context: *anyopaque, options: HoverActionOptions) IEditorHoverAction {
        const self: *EditorHoverStatusBar = @ptrCast(@alignCast(context));
        const noop = IEditorHoverAction{ .context = self, .set_enabled = noopSetEnabled };
        const label = self.allocator.dupe(u8, options.label) catch return noop;
        const command_id = self.allocator.dupe(u8, options.command_id) catch {
            self.allocator.free(label);
            return noop;
        };
        const index = self.actions.items.len;
        self.actions.append(.{
            .label = label,
            .command_id = command_id,
            .run = options.run,
            .run_context = options.run_context,
            .run_at = options.run_at,
        }) catch {
            self.allocator.free(label);
            self.allocator.free(command_id);
            return noop;
        };
        const handle = self.allocator.create(ActionHandle) catch return .{
            .context = self,
            .set_enabled = noopSetEnabled,
        };
        handle.* = .{ .bar = self, .index = index };
        self.handles.append(handle) catch {
            self.allocator.destroy(handle);
            return .{ .context = self, .set_enabled = noopSetEnabled };
        };
        return .{
            .context = handle,
            .set_enabled = setEnabled,
        };
    }

    fn noopSetEnabled(_: *anyopaque, _: bool) void {}

    fn hasContentCallback(context: *anyopaque) bool {
        const self: *EditorHoverStatusBar = @ptrCast(@alignCast(context));
        return self.hasContent();
    }

    fn append(context: *anyopaque, node: *ui.Node) void {
        _ = context;
        _ = node;
        // Participants only use `append` for the color picker in upstream,
        // which has no terminal counterpart. Keeping the hook explicit makes
        // the missing piece visible instead of silently laying out DOM nodes.
    }

    fn setEnabled(context: *anyopaque, enabled: bool) void {
        const handle: *ActionHandle = @ptrCast(@alignCast(context));
        if (handle.index < handle.bar.actions.items.len) {
            handle.bar.actions.items[handle.index].enabled = enabled;
        }
    }

    pub fn measureWidth(self: *const EditorHoverStatusBar) usize {
        if (!self.hasContent()) return 0;
        var width: usize = 1;
        if (self.message) |message| width += textWidth(message) + 1;
        for (self.actions.items) |action| width += textWidth(action.label) + 3;
        return width;
    }

    fn advance(width: usize, length: usize, column: *usize, row: *usize) usize {
        if (column.* > 0 and length > width -| column.*) {
            column.* = 0;
            row.* += 1;
        }
        const left = column.*;
        column.* = @min(width, left +| length +| 1);
        return left;
    }

    pub fn heightAt(self: *const EditorHoverStatusBar, width: usize) usize {
        if (!self.hasContent() or width == 0) return 0;
        var column: usize = 0;
        var row: usize = 0;
        if (self.message) |message| _ = advance(width, textWidth(message), &column, &row);
        for (self.actions.items) |action| _ = advance(width, textWidth(action.label) + 2, &column, &row);
        return row + 1;
    }

    /// Builds the status rows at `top`, allowing all actions to remain in
    /// the hover's normal scroll/focus order at narrow terminal widths.
    pub fn build(self: *EditorHoverStatusBar, doc: *ui.Document, parent: *ui.Node, width: usize, top: usize) !usize {
        const height = self.heightAt(width);
        if (height == 0) return 0;

        const row = try doc.createElement(.div);
        row.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = @floatFromInt(top) },
            .width = .{ .percent = 100 },
            .height = .{ .cells = @floatFromInt(height) },
            .white_space = .pre,
            .background = background,
            .color = foreground,
            .overflow = .hidden,
        });
        _ = try parent.appendChild(row);
        self.node = row;

        var column: usize = 0;
        var row_offset: usize = 0;
        if (self.message) |message| {
            const length = textWidth(message);
            const left = advance(width, length, &column, &row_offset);
            const placeholder = try doc.createElement(.div);
            placeholder.setStyle(.{ .position = .absolute, .left = .{ .cells = @floatFromInt(left) }, .top = .{ .cells = @floatFromInt(row_offset) }, .width = .{ .cells = @floatFromInt(@min(length, width -| left)) }, .height = .{ .cells = 1 }, .overflow = .hidden });
            _ = try placeholder.appendChild(try doc.createText(message));
            _ = try row.appendChild(placeholder);
        }
        for (self.actions.items, 0..) |action, index| {
            const label = try std.fmt.allocPrint(doc.allocator, "[{s}]", .{action.label});
            defer doc.allocator.free(label);
            const label_width = doc.measureText(label);
            const left = advance(width, label_width, &column, &row_offset);

            const action_node = try doc.createElement(.div);
            action_node.asElement().focusable = action.enabled;
            var index_buffer: [32]u8 = undefined;
            try action_node.setAttribute("data-hover-status-action", try std.fmt.bufPrint(&index_buffer, "{d}", .{index}));
            action_node.setStyle(.{
                .height = .{ .cells = 1 },
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(left) },
                .top = .{ .cells = @floatFromInt(row_offset) },
                .width = .{ .cells = @floatFromInt(@min(label_width, width -| left)) },
                .overflow = .hidden,
                .white_space = .pre,
                .flex_shrink = 0,
                .color = if (action.enabled) action_color else foreground,
                .pointer = .pointer,
            });
            const text = try doc.createText(label);
            _ = try action_node.appendChild(text);
            const state = try doc.arena.allocator().create(ActionState);
            state.* = .{ .bar = self, .index = index, .node = action_node };
            try action_node.addEventListener(.{
                .context = state,
                .click = onClick,
                .key_down = onKey,
            });
            _ = try row.appendChild(action_node);
        }
        return height;
    }

    const ActionState = struct {
        bar: *EditorHoverStatusBar,
        index: usize,
        node: *ui.Node,
    };

    fn onClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const state: *ActionState = @ptrCast(@alignCast(context orelse return));
        if (state.index >= state.bar.actions.items.len) return;
        if (!state.bar.actions.items[state.index].enabled) return;
        event.preventDefault();
        event.stopPropagation();
        activate(state);
    }

    fn onKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
        if (event.key != .enter and !(event.key == .char and event.key.char == ' ')) return;
        const state: *ActionState = @ptrCast(@alignCast(context orelse return));
        if (state.index >= state.bar.actions.items.len or !state.bar.actions.items[state.index].enabled) return;
        event.preventDefault();
        event.stopPropagation();
        activate(state);
    }

    fn activate(state: *ActionState) void {
        const action = state.bar.actions.items[state.index];
        if (action.run_at) |run| run(action.run_context, state.node) else if (action.run) |run| run(action.run_context);
    }
};

test "status bar: no content by default" {
    var bar = EditorHoverStatusBar.init(std.testing.allocator);
    defer bar.deinit();
    try std.testing.expect(!bar.hasContent());
}

test "status bar: renders action labels in one row" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var bar = EditorHoverStatusBar.init(allocator);
    defer bar.deinit();
    const iface = bar.interface();
    _ = iface.add_action(iface.context, .{ .label = "Copy", .command_id = "test.copy" });
    try testing.expect(bar.hasContent());

    var doc = try ui.Document.init(allocator, .{ .cols = 40, .rows = 4 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });

    const rows = try bar.build(&doc, root, 40, 1);
    try testing.expectEqual(@as(usize, 1), rows);

    const text = try root.textContentAlloc(allocator);
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "[Copy]") != null);
}

test "status bar: transient message and distinct focusable actions retain their indices at narrow widths" {
    const a = std.testing.allocator;
    const Probe = struct {
        first: usize = 0,
        second: usize = 0,
        fn activate(context: ?*anyopaque, target: *ui.Node) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const index = target.getAttribute("data-hover-status-action").?;
            if (std.mem.eql(u8, index, "0")) self.first += 1 else self.second += 1;
        }
    };
    var probe: Probe = .{};
    var bar = EditorHoverStatusBar.init(a);
    defer bar.deinit();
    const iface = bar.interface();
    iface.set_message.?(iface.context, "Checking for quick fixes...");
    const first = iface.add_action(iface.context, .{ .label = "Quick Fix...", .run_at = Probe.activate, .run_context = &probe });
    _ = iface.add_action(iface.context, .{ .label = "View Problem", .run_at = Probe.activate, .run_context = &probe });
    try std.testing.expect(bar.hasContent());
    try std.testing.expect(bar.measureWidth() > 20);
    try std.testing.expectEqual(@as(usize, 3), bar.heightAt(16));
    iface.set_message.?(iface.context, null);
    try std.testing.expectEqual(@as(usize, 2), bar.heightAt(16));
    var doc = try ui.Document.init(a, .{ .cols = 16, .rows = 5 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{ .position = .absolute, .width = .{ .percent = 100 }, .height = .{ .percent = 100 } });
    doc.setRoot(root);
    _ = try bar.build(&doc, root, 16, 0);
    var grid = try ui.CellGrid.init(a, 16, 5);
    defer grid.deinit();
    try ui.paint.paintDocument(&doc, &grid);
    try std.testing.expect(doc.moveFocusWithin(root, .forward));
    _ = doc.dispatchKey(.enter, .{});
    try std.testing.expect(doc.moveFocusWithin(root, .forward));
    _ = doc.dispatchKey(.enter, .{});
    try std.testing.expectEqual(@as(usize, 1), probe.first);
    try std.testing.expectEqual(@as(usize, 1), probe.second);
    first.set_enabled(first.context, false);
    const node = bar.node.?.firstChild().?;
    var click: ui.MouseEvent = .{ .kind = .click, .x = 0, .y = 0 };
    doc.dispatchMouse(node, &click);
    try std.testing.expectEqual(@as(usize, 1), probe.first);
}
