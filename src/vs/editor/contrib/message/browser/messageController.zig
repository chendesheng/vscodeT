// Port of `src/vs/editor/contrib/message/browser/messageController.ts`.
// The content widget uses cell geometry; the browser fade-out animation is
// omitted. This retains the message's model anchor and event-driven lifetime.
const std = @import("std");
const ui = @import("ui");
const editor_browser = @import("../../../browser/editorBrowser.zig");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const css = @import("messageController_css.zig");
const EditorCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const actions = @import("../../../../platform/actions/common/actions.zig");
const context = @import("../../../../platform/contextkey/common/contextkey.zig");
const keys = @import("../../../../base/common/keyCodes.zig");
const weight = @backingInt(@import("../../../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingWeight.EditorContrib) + 30;

pub const MessageController = struct {
    pub const ID = "editor.contrib.messageController";
    allocator: std.mem.Allocator,
    editor: *Editor,
    view: ?*View = null,
    message: ?[]u8 = null,
    position: Position = Position.init(1, 1),
    mouse_bounds: ?Range = null,
    mouse_over_message: bool = false,
    blur_task: dispatch.Task = .{},
    cursor_listener: ?usize = null,
    model_listener: ?usize = null,
    mouse_listener: ?usize = null,
    focus_listener: ?usize = null,

    pub fn getOrCreate(editor: *Editor, view: *View, queue: *dispatch.Queue) !*MessageController {
        if (editor.getInstantiatedContribution(MessageController)) |existing| {
            try existing.bind(view, queue);
            return existing;
        }
        const self = try editor.allocator.create(MessageController);
        self.* = .{ .allocator = editor.allocator, .editor = editor };
        errdefer self.dispose();
        try self.bind(view, queue);
        try editor.registerOwnedContribution(MessageController, self, dispose);
        return self;
    }

    fn bind(self: *MessageController, view: *View, queue: *dispatch.Queue) !void {
        if (self.view == view) return;
        self.unbind();
        self.view = view;
        self.blur_task = .{ .queue = queue, .context = self, .run = onBlurTick };
        errdefer self.unbind();
        self.cursor_listener = try self.editor.on_did_change_cursor_position.listen(self, onCursor);
        self.model_listener = try self.editor.on_will_change_model.listen(self, onModel);
        self.mouse_listener = try self.editor.on_did_mouse_event.listen(self, onMouse);
        self.focus_listener = try self.editor.on_did_change_text_focus.listen(self, onFocus);
    }

    pub fn unbind(self: *MessageController) void {
        self.closeMessage();
        if (self.cursor_listener) |id| self.editor.on_did_change_cursor_position.unlisten(id);
        if (self.model_listener) |id| self.editor.on_will_change_model.unlisten(id);
        if (self.mouse_listener) |id| self.editor.on_did_mouse_event.unlisten(id);
        if (self.focus_listener) |id| self.editor.on_did_change_text_focus.unlisten(id);
        self.cursor_listener = null;
        self.model_listener = null;
        self.mouse_listener = null;
        self.focus_listener = null;
        self.view = null;
    }

    pub fn dispose(self: *MessageController) void {
        self.unbind();
        self.allocator.destroy(self);
    }

    pub fn isVisible(self: *const MessageController) bool {
        return self.message != null;
    }

    pub fn showMessage(self: *MessageController, message: []const u8, position: Position) !void {
        const view = self.view orelse return;
        if (!self.editor.hasModel()) return;
        self.closeMessage();
        self.message = try self.allocator.dupe(u8, message);
        errdefer self.closeMessage();
        self.position = position;
        _ = self.editor.revealLine(position.lineNumber, .CenterIfOutsideViewport);
        try view.addContentWidget(self.widget());
        self.editor.setInlineMessageVisible(true);
        view.invalidate();
    }

    pub fn closeMessage(self: *MessageController) void {
        self.blur_task.schedule(null);
        const message = self.message orelse return;
        self.message = null;
        self.mouse_bounds = null;
        self.mouse_over_message = false;
        if (self.view) |view| {
            view.removeContentWidget("messageoverlay") catch {};
            view.invalidate();
        }
        self.allocator.free(message);
        self.editor.setInlineMessageVisible(false);
    }

    fn onCursor(_: @import("../../../common/cursorEvents.zig").ICursorPositionChangedEvent, self: *MessageController) !void {
        self.closeMessage();
    }
    fn onModel(_: @import("../../../common/editorCommon.zig").IModelChangedEvent, self: *MessageController) !void {
        self.closeMessage();
    }
    fn onFocus(focused: bool, self: *MessageController) !void {
        if (focused) self.blur_task.schedule(null) else if (self.isVisible()) self.blur_task.post();
    }
    fn onBlurTick(context_value: *anyopaque, _: i64, _: bool) bool {
        const self: *MessageController = @ptrCast(@alignCast(context_value));
        if (!self.mouse_over_message) self.closeMessage();
        return false;
    }
    fn onMouse(event: editor_browser.EditorMouseEvent, self: *MessageController) !void {
        if (!self.isVisible() or event.event.kind != .move) return;
        if (event.target.type == .content_widget) {
            self.mouse_over_message = if (event.target.element) |element| element.getAttribute("data-message-overlay") != null else false;
        } else self.mouse_over_message = false;
        const position = event.target.position orelse return;
        if (self.mouse_bounds) |bounds| {
            if (!bounds.containsPosition(&position)) self.closeMessage();
        } else self.mouse_bounds = Range.init(@max(1, self.position.lineNumber -| 3), 1, position.lineNumber + 3, 1);
    }

    fn widgetId(_: *anyopaque) []const u8 {
        return "messageoverlay";
    }
    fn positionOf(context_value: *anyopaque) ?editor_browser.IContentWidgetPosition {
        const self: *MessageController = @ptrCast(@alignCast(context_value));
        if (!self.isVisible()) return null;
        const view = self.view orelse return null;
        const row = view.visibleRowOf(self.position) orelse return null;
        return .{ .position = self.position, .preference = if (row >= height(self)) .above else .below };
    }
    fn width(context_value: *anyopaque, cols: usize) usize {
        const self: *MessageController = @ptrCast(@alignCast(context_value));
        const text = self.message orelse return 0;
        var longest: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| longest = @max(longest, std.unicode.utf8CountCodepoints(line) catch line.len);
        return @min(cols, longest + 2);
    }
    fn height(context_value: *anyopaque) usize {
        const self: *MessageController = @ptrCast(@alignCast(context_value));
        const text = self.message orelse return 0;
        const cols = @max(self.editor.screen_width -| self.editor.gutterWidth() -| self.editor.scrollbar_width -| 2, 1);
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const line_width = std.unicode.utf8CountCodepoints(line) catch line.len;
            count += @max(1, (line_width + cols - 1) / cols);
        }
        return count + 2;
    }
    fn build(context_value: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *MessageController = @ptrCast(@alignCast(context_value));
        const root = try doc.createElement(.div);
        errdefer doc.destroy(root);
        try root.addClass(css.Class.monaco_editor_overlaymessage);
        try root.setAttribute("data-message-overlay", "true");
        const content = try doc.createElement(.div);
        try content.addClass(css.Class.message);
        try content.setAttribute("data-message-overlay", "true");
        _ = try content.appendChild(try doc.createText(self.message.?));
        _ = try root.appendChild(content);
        return root;
    }
    fn focusNode(_: *anyopaque) ?*ui.Node {
        return null;
    }
    fn isFocused(_: *anyopaque) bool {
        return false;
    }
    fn widget(self: *MessageController) editor_browser.IContentWidget {
        return .{ .context = self, .get_id = widgetId, .get_position = positionOf, .width = width, .height = height, .build = build, .focus_node = focusNode, .is_focused = isFocused };
    }
};

const message_visible = context.Expr{ .Defined = "messageVisible" };
pub const leave_message_action = blk: {
    var action = EditorCommand.action(.{ .id = "leaveEditorMessage", .title = "Close Editor Message", .precondition = &message_visible }, true, struct {
        fn run(editor: *Editor) !void {
            if (editor.getInstantiatedContribution(MessageController)) |controller| controller.closeMessage();
        }
    }.run);
    action.f1 = false;
    action.keybindings = &.{.{ .id = "leaveEditorMessage", .weight = weight, .when = &message_visible, .bindings = .{ .primary = @backingInt(keys.KeyCode.Escape) } }};
    break :blk action;
};
