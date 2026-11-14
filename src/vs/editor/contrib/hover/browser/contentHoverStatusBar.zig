// Port of `src/vs/editor/contrib/hover/browser/contentHoverStatusBar.ts`.
//
// Terminal adaptation: the status bar is a single row of `[Label]` actions at
// the bottom of the hover. Upstream looks up keybinding labels and sets hover
// tooltips; the TUI has no keybinding service, so actions are mouse-clickable
// only. Participants that add no actions (the markdown participant in this
// port) produce no status bar row.
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

const Action = struct {
    label: []const u8,
    command_id: []const u8,
    run: ?*const fn (context: ?*anyopaque) void,
    run_context: ?*anyopaque,
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
    }

    pub fn interface(self: *EditorHoverStatusBar) IEditorHoverStatusBar {
        return .{
            .context = self,
            .add_action = addAction,
            .has_content = hasContentCallback,
            .append = append,
        };
    }

    pub fn hasContent(self: *const EditorHoverStatusBar) bool {
        return self.actions.items.len > 0 or self.content_nodes > 0;
    }

    fn addAction(context: *anyopaque, options: HoverActionOptions) IEditorHoverAction {
        const self: *EditorHoverStatusBar = @ptrCast(@alignCast(context));
        const label = self.allocator.dupe(u8, options.label) catch "";
        const command_id = self.allocator.dupe(u8, options.command_id) catch "";
        const index = self.actions.items.len;
        self.actions.append(.{
            .label = label,
            .command_id = command_id,
            .run = options.run,
            .run_context = options.run_context,
        }) catch {};
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

    /// Builds the status row at `top`. Returns the number of rows (0 or 1).
    pub fn build(self: *EditorHoverStatusBar, doc: *ui.Document, parent: *ui.Node, width: usize, top: usize) !usize {
        if (!self.hasContent() or width == 0) return 0;

        const row = try doc.createElement(.div);
        row.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = @floatFromInt(top) },
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .display = .flex,
            .align_items = .center,
            .gap = .{ .column = 1 },
            .padding = .{ .left = 1 },
            .background = background,
            .color = foreground,
            .overflow = .hidden,
        });
        _ = try parent.appendChild(row);
        self.node = row;

        var column: usize = 1;
        for (self.actions.items) |action| {
            const label = try std.fmt.allocPrint(doc.allocator, "[{s}]", .{action.label});
            defer doc.allocator.free(label);
            const label_width = doc.measureText(label);
            if (column + label_width + 1 > width) break;

            const action_node = try doc.createElement(.div);
            action_node.asElement().focusable = false;
            action_node.setStyle(.{
                .height = .{ .cells = 1 },
                .flex_shrink = 0,
                .color = if (action.enabled) action_color else foreground,
            });
            const text = try doc.createText(label);
            _ = try action_node.appendChild(text);
            const state = try doc.arena.allocator().create(ActionState);
            state.* = .{ .bar = self, .index = self.actions.items.len - 1 };
            try action_node.addEventListener(.{
                .context = state,
                .click = onClick,
            });
            _ = try row.appendChild(action_node);
            column += label_width + 1;
        }
        return 1;
    }

    const ActionState = struct {
        bar: *EditorHoverStatusBar,
        index: usize,
    };

    fn onClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const state: *ActionState = @ptrCast(@alignCast(context orelse return));
        if (state.index >= state.bar.actions.items.len) return;
        const action = state.bar.actions.items[state.index];
        if (!action.enabled) return;
        event.preventDefault();
        if (action.run) |run| run(action.run_context);
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
