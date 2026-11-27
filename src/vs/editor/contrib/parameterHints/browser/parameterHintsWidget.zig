// Port of `src/vs/editor/contrib/parameterHints/browser/parameterHintsWidget.ts`.
// A cell content widget retains signature selection, parameter highlighting,
// documentation and overload controls. Markdown documentation is plain text
// here; rich markdown links/scrolling remain a portable rendering gap.
const std = @import("std");
const ui = @import("ui");
const editor_browser = @import("../../../browser/editorBrowser.zig");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const languages = @import("../../../common/languages.zig");
const ParameterHintsModel = @import("parameterHintsModel.zig").ParameterHintsModel;
const css = @import("parameterHints_css.zig");

// Parameter offsets have already been converted to UTF-8 bytes at the RPC boundary.
pub fn activeParameterLabel(signature: languages.SignatureInformation, index: usize) ?[2]usize {
    if (index >= signature.parameters.len) return null;
    return switch (signature.parameters[index].label) {
        .text => |label| if (std.mem.indexOf(u8, signature.label, label)) |start| .{ start, start + label.len } else null,
        .offsets => |offsets| blk: {
            const start = offsets[0];
            const end = offsets[1];
            break :blk if (start <= end and end <= signature.label.len) .{ start, end } else null;
        },
    };
}

pub const ParameterHintsWidget = struct {
    editor: *Editor,
    model: *ParameterHintsModel,
    view: ?*View = null,
    cols: usize = 60,

    pub const ID = "editor.widget.parameterHints";

    pub fn interface(self: *ParameterHintsWidget) editor_browser.IContentWidget {
        return .{ .context = self, .get_id = getId, .get_position = getPosition, .width = width, .height = height, .build = build, .focus_node = focusNode, .is_focused = focused };
    }

    fn getId(_: *anyopaque) []const u8 {
        return ID;
    }

    fn getPosition(context: *anyopaque) ?editor_browser.IContentWidgetPosition {
        const self: *ParameterHintsWidget = @ptrCast(@alignCast(context));
        if (self.model.hints() == null or !self.editor.hasModel()) return null;
        const view = self.view orelse return null;
        const position = self.editor.modelCursorPosition();
        const row = view.visibleRowOf(position) orelse return null;
        return .{ .position = position, .preference = if (row >= height(self)) .above else .below };
    }

    fn selected(self: *ParameterHintsWidget) ?struct { help: languages.SignatureHelp, signature: languages.SignatureInformation, parameter: usize } {
        const help = self.model.hints() orelse return null;
        if (help.signatures.len == 0) return null;
        const signature = help.signatures[@min(help.active_signature, help.signatures.len - 1)];
        return .{ .help = help, .signature = signature, .parameter = signature.active_parameter orelse help.active_parameter };
    }

    fn width(context: *anyopaque, cols: usize) usize {
        const self: *ParameterHintsWidget = @ptrCast(@alignCast(context));
        const data = self.selected() orelse return 0;
        var longest = data.signature.label.len;
        if (data.signature.documentation) |doc| {
            var lines = std.mem.splitScalar(u8, doc, '\n');
            while (lines.next()) |line| longest = @max(longest, line.len);
        }
        if (data.parameter < data.signature.parameters.len) if (data.signature.parameters[data.parameter].documentation) |doc| {
            var lines = std.mem.splitScalar(u8, doc, '\n');
            while (lines.next()) |line| longest = @max(longest, line.len);
        };
        const controls: usize = if (data.help.signatures.len > 1) 5 else 0;
        self.cols = @max(1, @min(cols, @max(12, @min(longest + controls + 2, 60))));
        return self.cols;
    }

    fn rows(text: []const u8, cols: usize) usize {
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const len = std.unicode.utf8CountCodepoints(line) catch line.len;
            count += @max(1, (len + cols - 1) / cols);
        }
        return count;
    }

    fn height(context: *anyopaque) usize {
        const self: *ParameterHintsWidget = @ptrCast(@alignCast(context));
        const data = self.selected() orelse return 0;
        const content_cols = @max(1, self.cols -| 2 -| @as(usize, if (data.help.signatures.len > 1) 5 else 0));
        var count = rows(data.signature.label, content_cols);
        if (data.signature.documentation) |doc| count += rows(doc, content_cols);
        if (data.parameter < data.signature.parameters.len) if (data.signature.parameters[data.parameter].documentation) |doc| {
            count += rows(doc, content_cols);
        };
        return @min(self.editor.screen_height, @max(if (data.help.signatures.len > 1) @as(usize, 3) else 1, count) + 2);
    }

    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *ParameterHintsWidget = @ptrCast(@alignCast(context));
        const data = self.selected() orelse return error.NoSignatureHelp;
        const root = try doc.createElement(.div);
        errdefer doc.destroy(root);
        try root.addClass(css.Class.parameter_hints_widget);
        try root.setAttribute("data-parameter-hints", "true");
        const wrapper = try doc.createElement(.div);
        try wrapper.addClass(css.Class.phwrapper);
        _ = try root.appendChild(wrapper);
        if (data.help.signatures.len > 1) {
            const controls = try doc.createElement(.div);
            try controls.addClass(css.Class.controls);
            const previous = try textElement(doc, "▲", css.Class.button);
            try previous.addEventListener(.{ .context = self, .click = onPrevious });
            _ = try controls.appendChild(previous);
            var buffer: [32]u8 = undefined;
            const count = try std.fmt.bufPrint(&buffer, "{d}/{d}", .{ data.help.active_signature + 1, data.help.signatures.len });
            _ = try controls.appendChild(try textElement(doc, count, css.Class.overloads));
            const next = try textElement(doc, "▼", css.Class.button);
            try next.addEventListener(.{ .context = self, .click = onNext });
            _ = try controls.appendChild(next);
            _ = try wrapper.appendChild(controls);
        }
        const body = try doc.createElement(.div);
        try body.addClass(css.Class.body);
        _ = try wrapper.appendChild(body);
        const signature = try doc.createElement(.div);
        try signature.addClass(css.Class.signature);
        try signature.addClass(css.Class.code);
        _ = try body.appendChild(signature);
        const label = data.signature.label;
        if (activeParameterLabel(data.signature, data.parameter)) |span| {
            _ = try signature.appendChild(try doc.createText(label[0..span[0]]));
            const active = try doc.createElement(.span);
            try active.addClass(css.Class.parameter_active);
            try active.setAttribute("data-parameter-active", "true");
            _ = try active.appendChild(try doc.createText(label[span[0]..span[1]]));
            _ = try signature.appendChild(active);
            _ = try signature.appendChild(try doc.createText(label[span[1]..]));
        } else _ = try signature.appendChild(try doc.createText(label));
        if (data.parameter < data.signature.parameters.len) if (data.signature.parameters[data.parameter].documentation) |text| {
            _ = try body.appendChild(try textElement(doc, text, css.Class.docs));
        };
        if (data.signature.documentation) |text| {
            _ = try body.appendChild(try textElement(doc, text, css.Class.docs));
        }
        return root;
    }

    fn textElement(doc: *ui.Document, text: []const u8, class: css.Class) !*ui.Node {
        const node = try doc.createElement(.div);
        errdefer doc.destroy(node);
        try node.addClass(class);
        _ = try node.appendChild(try doc.createText(text));
        return node;
    }
    fn onPrevious(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *ParameterHintsWidget = @ptrCast(@alignCast(context orelse return));
        self.model.move(false);
        event.preventDefault();
    }
    fn onNext(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *ParameterHintsWidget = @ptrCast(@alignCast(context orelse return));
        self.model.move(true);
        event.preventDefault();
    }
    fn focusNode(_: *anyopaque) ?*ui.Node {
        return null;
    }
    fn focused(_: *anyopaque) bool {
        return false;
    }
};
