// Port of `src/vs/editor/contrib/inlayHints/browser/inlayHintsHover.ts`.
// A foreign-element anchor identifies the injected label part. Resolve through
// the provider before producing the shared markdown hover parts; the owning
// controller invalidates pending hover work before disposing result caches.
const std = @import("std");
const ui = @import("ui");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const EditorMouseEvent = @import("../../hover/browser/hoverTypes.zig").EditorMouseEvent;
const Range = @import("../../../common/core/range.zig").Range;
const ModelDecoration = @import("../../../common/model.zig").ModelDecoration;
const languages = @import("../../../common/languages.zig");
const hover = @import("../../hover/browser/hoverTypes.zig");
const Markdown = @import("../../hover/browser/markdownHoverParticipant.zig");
const ContentHoverController = @import("../../hover/browser/contentHoverController.zig").ContentHoverController;
const AsyncSink = @import("../../hover/browser/hoverOperation.zig").AsyncResultSink(hover.IHoverPart);
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const InlayHintsController = @import("inlayHintsController.zig").InlayHintsController;
const Part = @import("inlayHints.zig").RenderedInlayHintLabelPart;

pub const InlayHintsHover = struct {
    editor: *Editor,
    markdown: Markdown.MarkdownHoverParticipant,
    arena: std.heap.ArenaAllocator,
    controller: ?*InlayHintsController = null,
    listener: ?usize = null,
    part: ?*Part = null,
    range: Range = Range.init(1, 1, 1, 1),
    sink: ?AsyncSink = null,
    pending: ?IDisposable = null,
    starting: bool = false,
    inline_result: ?anyerror!?languages.InlayHint = null,

    pub fn init(editor: *Editor) InlayHintsHover {
        return .{ .editor = editor, .markdown = Markdown.MarkdownHoverParticipant.init(editor.allocator, editor.model, &.{}), .arena = .init(editor.allocator) };
    }
    pub fn deinit(self: *InlayHintsHover) void {
        self.cancel();
        self.markdown.deinit();
        self.arena.deinit();
    }
    pub fn setCodeBackground(self: *InlayHintsHover, color: ?ui.Color) void {
        self.markdown.setCodeBackground(color);
    }
    pub fn interface(self: *InlayHintsHover) hover.IEditorHoverParticipant {
        return .{ .context = self, .hover_ordinal = 6, .suggest_hover_anchor = suggestAnchor, .request_async = requestAsync, .render_hover_parts = renderParts, .get_accessible_content = accessibleContent, .handle_hide = hide };
    }
    fn suggestAnchor(context: *anyopaque, event: EditorMouseEvent) ?hover.HoverAnchor {
        const self: *InlayHintsHover = @ptrCast(@alignCast(context));
        const controller = self.editor.getInstantiatedContribution(InlayHintsController) orelse return null;
        const part = controller.partFromTarget(event.target) orelse return null;
        return .{ .foreign_element = .{ .priority = 10, .owner = part, .range = part.item.anchor.range, .initial_mouse_pos_x = @floatFromInt(event.x), .initial_mouse_pos_y = @floatFromInt(event.y), .supports_marker_hover = true } };
    }
    fn cancel(self: *InlayHintsHover) void {
        if (self.pending) |pending| pending.dispose();
        self.pending = null;
        if (self.listener) |id| self.controller.?.on_will_change_hints.unlisten(id);
        self.listener = null;
        self.controller = null;
        self.sink = null;
        self.part = null;
    }
    fn hide(context: *anyopaque) void {
        const self: *InlayHintsHover = @ptrCast(@alignCast(context));
        self.cancel();
    }
    fn disposeRequest(context: *anyopaque) void {
        hide(context);
    }
    fn onChange(_: void, self: *InlayHintsHover) !void {
        const sink = self.sink;
        self.cancel();
        if (sink) |value| value.complete(value.context);
        if (self.editor.getInstantiatedContribution(ContentHoverController)) |controller| controller.hideContentHover();
    }
    fn requestAsync(context: *anyopaque, anchor: *const hover.HoverAnchor, _: []const ModelDecoration, _: hover.HoverStartSource, token: CancellationToken, sink: AsyncSink) !?IDisposable {
        const self: *InlayHintsHover = @ptrCast(@alignCast(context));
        self.cancel();
        if (anchor.* != .foreign_element or token.isCancellationRequested()) {
            sink.complete(sink.context);
            return null;
        }
        const controller = self.editor.getInstantiatedContribution(InlayHintsController) orelse {
            sink.complete(sink.context);
            return null;
        };
        const part = controller.partByIdentity(anchor.foreign_element.owner) orelse {
            sink.complete(sink.context);
            return null;
        };
        if (controller.model == null or controller.active == null or controller.model.?.getVersionId() != controller.active_version) {
            sink.complete(sink.context);
            return null;
        }
        _ = self.arena.reset(.retain_capacity);
        self.controller = controller;
        self.part = part;
        self.range = anchor.getRange();
        self.sink = sink;
        errdefer self.cancel();
        self.listener = try controller.on_will_change_hints.listen(self, onChange);
        if (!part.item.resolved) if (part.item.provider.resolve_inlay_hint) |resolve| {
            self.starting = true;
            const request = resolve(part.item.provider.context, controller.active.?.arena.allocator(), controller.model.?, part.item.hint, .{ .context = self, .complete = resolveReady }) catch {
                self.starting = false;
                self.emit();
                return null;
            };
            self.starting = false;
            if (self.inline_result) |reply| {
                self.inline_result = null;
                resolveReady(self, reply);
                return null;
            }
            self.pending = request;
            return .{ .context = self, .disposeFn = disposeRequest };
        };
        self.emit();
        return null;
    }
    fn resolveReady(context: *anyopaque, result: anyerror!?languages.InlayHint) void {
        const self: *InlayHintsHover = @ptrCast(@alignCast(context));
        if (self.starting) {
            self.inline_result = result;
            return;
        }
        self.pending = null;
        const part = self.part orelse return;
        if (result catch null) |hint| {
            part.item.hint = hint;
            part.item.resolved = true;
        }
        self.emit();
    }
    fn appendPart(self: *InlayHintsHover, result: *std.ArrayList(hover.IHoverPart), text: []const u8, ordinal: usize) !void {
        if (text.len == 0) return;
        const a = self.arena.allocator();
        const contents = try a.alloc(languages.IMarkdownString, 1);
        contents[0] = .{ .value = try a.dupe(u8, text) };
        const markdown = try a.create(Markdown.MarkdownHover);
        markdown.* = .{ .range = self.range, .contents = contents, .ordinal = ordinal, .is_before_content = false };
        try result.append(a, .{ .owner = self, .range = self.range, .data = markdown, .is_valid_for_hover_anchor = isValid });
    }
    fn isValid(part: *const hover.IHoverPart, anchor: *const hover.HoverAnchor) bool {
        return anchor.* == .foreign_element and Range.equalsRange(part.range, anchor.getRange());
    }
    fn emit(self: *InlayHintsHover) void {
        const sink = self.sink orelse return;
        const part = self.part orelse return;
        var result: std.ArrayList(hover.IHoverPart) = .empty;
        if (part.item.hint.tooltip) |text| self.appendPart(&result, text, 0) catch {};
        if (part.index < part.item.hint.label.len) {
            const label = part.item.hint.label[part.index];
            if (label.tooltip) |text| self.appendPart(&result, text, 1) catch {};
            if (label.location != null or label.command != null) {
                const modifier = if (self.controller.?.alt_link) "Alt+click" else "Ctrl+click";
                const operation = if (label.location != null) "Go to Definition" else "Execute Command";
                const text = std.fmt.allocPrint(self.arena.allocator(), "{s} ({s})", .{ operation, modifier }) catch "";
                self.appendPart(&result, text, 10000) catch {};
            }
        }
        if (part.item.hint.text_edits.len > 0) self.appendPart(&result, "Double-click to insert", 10001) catch {};
        self.sink = null;
        if (result.items.len > 0) sink.emit(sink.context, result.items);
        sink.complete(sink.context);
    }
    fn renderParts(context: *anyopaque, rc: *const hover.IEditorHoverRenderContext, parts: []const hover.IHoverPart) ![]const hover.IRenderedHoverPart {
        const self: *InlayHintsHover = @ptrCast(@alignCast(context));
        const participant = self.markdown.interface();
        return participant.render_hover_parts.?(participant.context, rc, parts);
    }
    fn accessibleContent(context: *anyopaque, part: *const hover.IHoverPart) []const u8 {
        const self: *InlayHintsHover = @ptrCast(@alignCast(context));
        const participant = self.markdown.interface();
        return participant.get_accessible_content.?(participant.context, part);
    }
};
