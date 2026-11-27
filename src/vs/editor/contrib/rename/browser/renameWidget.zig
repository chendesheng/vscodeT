// Port of `src/vs/editor/contrib/rename/browser/renameWidget.ts`.
// The shared terminal InputBox replaces the HTML input and native DOM focus.
// New-symbol-name suggestion providers (not advertised by ZLS) remain unported.
const std = @import("std");
const ui = @import("ui");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const editor_browser = @import("../../../browser/editorBrowser.zig");
const Position = @import("../../../common/core/position.zig").Position;
const css = @import("renameWidget_css.zig");

pub const RenameWidget = struct {
    input: ui.InputBox,
    view: ?*View = null,
    position: Position = .{ .lineNumber = 1, .column = 1 },
    visible: bool = false,
    cols: usize = 34,
    preview: bool = false,
    focus_node: ?*ui.Node = null,
    listener: ?Listener = null,
    pub const ID = "__renameInputWidget";
    pub const Listener = struct { context: *anyopaque, accept: *const fn (*anyopaque, bool) void, cancel: *const fn (*anyopaque) void };

    pub fn init(a: std.mem.Allocator) RenameWidget {
        return .{ .input = ui.InputBox.init(a) };
    }
    pub fn deinit(self: *RenameWidget) void {
        self.hide();
        self.input.deinit();
    }
    pub fn show(self: *RenameWidget, view: *View, position: Position, name: []const u8, preview: bool, listener: Listener) !void {
        self.hide();
        self.view = view;
        self.position = position;
        self.preview = preview;
        self.listener = listener;
        try self.input.setValue(name);
        self.input.selectAll();
        self.input.focused = true;
        self.input.callback_context = self;
        self.input.on_change = changed;
        self.visible = true;
        errdefer self.hide();
        try view.addContentWidget(self.interface());
        view.invalidate();
    }
    pub fn hide(self: *RenameWidget) void {
        if (self.visible) if (self.view) |view| {
            view.removeContentWidget(ID) catch {};
            view.invalidate();
        };
        self.visible = false;
        self.input.focused = false;
        self.focus_node = null;
        self.view = null;
        self.listener = null;
    }
    pub fn interface(self: *RenameWidget) editor_browser.IContentWidget {
        return .{ .context = self, .get_id = id, .get_position = getPosition, .width = width, .height = height, .build = build, .focus_node = focusNode, .is_focused = focused };
    }
    fn id(_: *anyopaque) []const u8 {
        return ID;
    }
    fn getPosition(context: *anyopaque) ?editor_browser.IContentWidgetPosition {
        const self: *RenameWidget = @ptrCast(@alignCast(context));
        if (!self.visible) return null;
        return .{ .position = self.position, .preference = .below };
    }
    fn width(context: *anyopaque, cols: usize) usize {
        const self: *RenameWidget = @ptrCast(@alignCast(context));
        self.cols = @min(cols, @max(if (self.preview) @as(usize, 34) else 20, self.input.getValue().len + 4));
        return self.cols;
    }
    fn height(context: *anyopaque) usize {
        const self: *RenameWidget = @ptrCast(@alignCast(context));
        return if (self.preview) 4 else 3;
    }
    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *RenameWidget = @ptrCast(@alignCast(context));
        const root = try doc.createElement(.div);
        errdefer doc.destroy(root);
        try root.addClass(css.Class.rename_box);
        if (self.preview) try root.addClass(css.Class.preview);
        try root.addEventListener(.{ .context = self, .capture = true, .key_down = onKey });
        const holder = try doc.createElement(.div);
        try holder.addClass(css.Class.rename_input_with_button);
        _ = try root.appendChild(holder);
        self.input.focused = true;
        self.focus_node = try self.input.build(doc, @max(1, self.cols -| 2));
        try self.focus_node.?.addClass(css.Class.rename_input);
        _ = try holder.appendChild(self.focus_node.?);
        if (self.preview) {
            const label = try doc.createElement(.div);
            try label.addClass(css.Class.rename_label);
            _ = try label.appendChild(try doc.createText("Enter: Rename · Ctrl+Enter: Preview"));
            _ = try root.appendChild(label);
        }
        return root;
    }
    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *RenameWidget = @ptrCast(@alignCast(context));
        return self.focus_node;
    }
    fn focused(context: *anyopaque) bool {
        const self: *RenameWidget = @ptrCast(@alignCast(context));
        return self.visible;
    }
    fn changed(context: ?*anyopaque, _: []const u8) void {
        const self: *RenameWidget = @ptrCast(@alignCast(context orelse return));
        if (self.view) |view| view.invalidate();
    }
    fn onKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
        const self: *RenameWidget = @ptrCast(@alignCast(context orelse return));
        const listener = self.listener orelse return;
        switch (event.key) {
            .enter => listener.accept(listener.context, self.preview and event.mods.ctrl),
            .escape => listener.cancel(listener.context),
            else => return,
        }
        event.preventDefault();
        event.stopPropagation();
    }
};
