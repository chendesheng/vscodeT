// Port of `src/vs/editor/contrib/codeAction/browser/lightBulbWidget.ts`.
// The content widget uses one terminal cell; the gutter fallback uses the
// shared glyph-margin widget view part (the native clickable equivalent of
// upstream's decorated glyph lane). Pixel/font geometry is rounded to cells.
const std = @import("std");
const ui = @import("ui");
const browser = @import("../../../browser/editorBrowser.zig");
const View = @import("../../../browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const css = @import("lightBulbWidget_css.zig");
const codeAction = @import("codeAction.zig");
const model = @import("codeActionModel.zig");
const Anchor = @import("../../../../platform/contextview/browser/contextMenuService.zig").Anchor;

pub const LightBulbInfo = struct { icon: u21, auto_run: bool, preferred: bool, ai: bool, all_ai: bool };
pub fn computeLightBulbInfo(actions: *const codeAction.ManagedCodeActionSet) ?LightBulbInfo {
    if (actions.valid_actions.len == 0) return null;
    const ai = actions.hasAIFix();
    const all_ai = actions.allAIFixes();
    return .{ .icon = if (all_ai) '✦' else if (actions.hasAutoFix()) (if (ai) '✧' else '◆') else if (ai) '✧' else '◉', .auto_run = all_ai and actions.valid_actions.len == 1, .preferred = actions.hasAutoFix(), .ai = ai, .all_ai = all_ai };
}

pub const LightBulbWidget = struct {
    pub const ID = "LightBulbWidget";
    view: *View,
    context: *anyopaque,
    on_click: *const fn (*anyopaque, Anchor) void,
    position: ?Position = null,
    gutter_position: ?Position = null,
    info: ?LightBulbInfo = null,
    attached: bool = false,
    only_with_empty_selection: bool = false,

    pub fn bind(self: *LightBulbWidget) !void {
        if (self.attached) return;
        try self.view.addContentWidget(self.contentWidget());
        self.attached = true;
    }
    pub fn unbind(self: *LightBulbWidget) void {
        self.hide();
        if (self.attached) self.view.removeContentWidget(ID) catch {};
        self.attached = false;
    }

    pub fn hide(self: *LightBulbWidget) void {
        if (self.gutter_position != null) self.view.terminal_view_host.removeGlyphMarginWidget(ID);
        const changed = self.position != null or self.gutter_position != null;
        self.position = null;
        self.gutter_position = null;
        self.info = null;
        if (changed) self.view.invalidate();
    }

    fn emptyOrIndented(text_model: *TextModel, line: usize) bool {
        const contents = text_model.borrowLineContent(line) catch return false;
        return contents.len <= 1 or std.ascii.isWhitespace(contents[0]);
    }

    fn hasGlyphDecoration(text_model: *TextModel, line: usize) bool {
        const decorations = text_model.getLineDecorations(line, 0, false) catch return false;
        defer text_model.getAllocator().free(decorations);
        for (decorations) |decoration| {
            if (decoration.options.glyphMarginClassName) |class_name| {
                if (std.mem.indexOf(u8, class_name, "codicon-gutter-lightbulb") == null) return true;
            }
        }
        return false;
    }

    pub fn update(self: *LightBulbWidget, actions: *const codeAction.ManagedCodeActionSet, at: Position, enabled: model.LightbulbMode) void {
        self.hide();
        const info = computeLightBulbInfo(actions) orelse return;
        if (enabled == .off or !self.view.isFocused() or !self.view.hasEditorFocus()) return;
        if (self.only_with_empty_selection and !self.view.editor.modelSelection().isEmpty()) return;
        const editor = self.view.editor;
        const text_model = editor.getModel() orelse return;
        const line = text_model.borrowLineContent(at.lineNumber) catch return;
        var indent: usize = 0;
        for (line) |c| {
            if (c == ' ') indent += 1 else if (c == '\t') indent += editor.tabSize() - indent % editor.tabSize() else break;
        }
        var effective = at.lineNumber;
        var column: usize = 1;
        var gutter = false;
        if (indent < 3) {
            const line_count = text_model.getLineCount();
            const last = at.lineNumber == line_count;
            const current_empty = emptyOrIndented(text_model, at.lineNumber);
            const previous = at.lineNumber > 1 and emptyOrIndented(text_model, at.lineNumber - 1);
            const next = !last and emptyOrIndented(text_model, at.lineNumber + 1);
            const has_decoration = hasGlyphDecoration(text_model, at.lineNumber);
            if (at.lineNumber > 1 and editor.isModelLineVisible(at.lineNumber - 1)) {
                if (!next and !previous and !has_decoration) {
                    gutter = editor.gutterGlyphWidth() > 0;
                    if (!gutter) return;
                } else if (previous or last) {
                    effective -= 1;
                } else if (next or (!next and !previous and current_empty)) {
                    effective += 1;
                }
            } else if (at.lineNumber == 1 and (last or (!next and !current_empty))) {
                gutter = !has_decoration and editor.gutterGlyphWidth() > 0;
                if (!gutter and !has_decoration) return;
            } else if (!last and editor.isModelLineVisible(at.lineNumber + 1)) {
                effective += 1;
            } else if (at.column <= 2) return;
            const contents = text_model.borrowLineContent(effective) catch return;
            if (contents.len > 0 and !std.ascii.isWhitespace(contents[0]) and std.mem.trim(u8, contents[1..], " \t\r\n").len == 0) column = 2;
        }
        self.info = info;
        if (gutter) {
            self.gutter_position = Position.init(effective, 1);
            self.view.terminal_view_host.addGlyphMarginWidget(self.gutterWidget()) catch {
                self.gutter_position = null;
                self.info = null;
                return;
            };
        } else self.position = Position.init(effective, column);
        self.view.invalidate();
    }

    fn id(_: *anyopaque) []const u8 {
        return ID;
    }
    fn positionOf(context: *anyopaque) ?browser.IContentWidgetPosition {
        const self: *LightBulbWidget = @ptrCast(@alignCast(context));
        return if (self.position) |position| .{ .position = position, .preference = .exact } else null;
    }
    fn width(_: *anyopaque, _: usize) usize {
        return 1;
    }
    fn height(_: *anyopaque) usize {
        return 1;
    }
    fn focusNode(_: *anyopaque) ?*ui.Node {
        return null;
    }
    fn focused(_: *anyopaque) bool {
        return false;
    }
    fn contentWidget(self: *LightBulbWidget) browser.IContentWidget {
        return .{ .context = self, .get_id = id, .get_position = positionOf, .width = width, .height = height, .build = build, .focus_node = focusNode, .is_focused = focused };
    }
    fn color(self: *LightBulbWidget) ui.Color {
        const palette = @import("../../../../workbench/browser/themeColors.zig").ThemeColors.lightBulbTheme(self.view.themeColors());
        const info = self.info.?;
        return if (info.all_ai) palette.ai else if (info.preferred) palette.preferred else palette.normal;
    }
    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *LightBulbWidget = @ptrCast(@alignCast(context));
        const root = try doc.createElement(.div);
        try root.addClass(css.Class.light_bulb_widget);
        try root.addClass(if (self.info.?.all_ai) css.Class.codicon_sparkle_filled else if (self.info.?.preferred) css.Class.codicon_lightbulb_autofix else css.Class.codicon_light_bulb);
        try root.setAttribute("aria-label", "Show Code Actions");
        var buffer: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(self.info.?.icon, &buffer);
        _ = try root.appendChild(try doc.createText(buffer[0..len]));
        try root.addEventListener(.{ .context = self, .mouse_down = onDown, .click = onClick });
        return root;
    }
    fn onDown(_: ?*anyopaque, event: *ui.MouseEvent) void {
        event.preventDefault();
        event.stopPropagation();
    }
    fn onClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *LightBulbWidget = @ptrCast(@alignCast(context orelse return));
        self.on_click(self.context, .{ .x = event.x, .y = event.y + 1 });
        event.preventDefault();
        event.stopPropagation();
    }
    fn gutterWidget(self: *LightBulbWidget) browser.IGlyphMarginWidget {
        return .{ .context = self, .get_id = id, .get_position = gutterPosition, .get_presentation = gutterPresentation, .handle_mouse = gutterMouse };
    }
    fn gutterPosition(context: *anyopaque) browser.IGlyphMarginWidgetPosition {
        const self: *LightBulbWidget = @ptrCast(@alignCast(context));
        const position = self.gutter_position.?;
        return .{ .lane = .Left, .range = Range.init(position.lineNumber, 1, position.lineNumber, 1), .zIndex = 0 };
    }
    fn gutterPresentation(context: *anyopaque) browser.IGlyphMarginWidget.Presentation {
        const self: *LightBulbWidget = @ptrCast(@alignCast(context));
        return .{ .codepoint = self.info.?.icon, .color = self.color(), .class_name = "codicon-gutter-lightbulb", .tooltip = "Show Code Actions" };
    }
    fn gutterMouse(context: *anyopaque, event: *ui.MouseEvent) !bool {
        const self: *LightBulbWidget = @ptrCast(@alignCast(context));
        if (event.kind == .down) {
            const mount = self.view.surfaceContext();
            self.on_click(self.context, .{ .x = mount.x + event.x, .y = mount.y + event.y + 1, .opening_press = true });
            return true;
        }
        return false;
    }
};
