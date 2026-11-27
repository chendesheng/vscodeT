// Port of `src/vs/editor/contrib/inlayHints/browser/inlayHintsController.ts`.
// Provider fragments become tracked injected-text decorations and retain their
// label-part metadata through view projection and mouse hit testing. Window
// deadlines replace browser timers. Fixed terminal cells replace pixel fonts.
const std = @import("std");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const EditorMouseEvent = @import("../../../browser/editorBrowser.zig").EditorMouseEvent;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Range = @import("../../../common/core/range.zig").Range;
const languages = @import("../../../common/languages.zig");
const model_types = @import("../../../common/model.zig");
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.InlayHintsProvider);
const fragments = @import("inlayHints.zig");
const Fragments = fragments.InlayHintsFragments;
const Part = fragments.RenderedInlayHintLabelPart;
const styles = @import("inlayHintsContribution.zig");
const locations = @import("inlayHintsLocations.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");
const positions = @import("../../../../base/common/utf16Position.zig");
const events = @import("../../../common/textModelEvents.zig");
const editor_common = @import("../../../common/editorCommon.zig");
const ScrollEvent = @import("../../../../base/common/scrollable.zig").ScrollEvent;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const Options = @import("../../../common/config/editorOptions.zig").EditorInlayHintsOptions;
const opener_mod = @import("../../../../platform/opener/common/opener.zig");

pub const Services = struct { registry: *Registry, window: *dispatch.Queue, opener: opener_mod.IOpenerService, commands: languages.CommandHost };
pub const InlayHintsController = struct {
    pub const ID = "editor.contrib.inlayHints";
    editor: *Editor,
    services: ?Services = null,
    model: ?*TextModel = null,
    options: Options = .{},
    alt_link: bool = false,
    timer: dispatch.Task = .{},
    pending: ?*Fragments = null,
    active: ?*Fragments = null,
    request_version: u32 = 0,
    active_version: u32 = 0,
    decorations: []u64 = &.{},
    parts: []const *Part = &.{},
    on_will_change_hints: Emitter(void),
    scroll_listener: ?usize = null,
    registry_listener: ?usize = null,
    content_listener: ?usize = null,
    language_listener: ?usize = null,
    will_change_listener: ?usize = null,
    did_change_listener: ?usize = null,
    mouse_listener: ?usize = null,
    provider_listeners: std.ArrayList(ProviderListener) = .empty,
    click_pending: ?IDisposable = null,
    click_part: ?*Part = null,
    click_insert: bool = false,
    click_starting: bool = false,
    inline_resolve: ?anyerror!?languages.InlayHint = null,
    last_click_part: ?*Part = null,
    last_click_ms: i64 = 0,
    const ProviderListener = struct { emitter: *Emitter(void), id: usize };

    pub fn getOrCreate(editor: *Editor, services: Services, options: Options) !*InlayHintsController {
        if (editor.getInstantiatedContribution(InlayHintsController)) |self| {
            try self.bind(services, options);
            return self;
        }
        const self = try editor.allocator.create(InlayHintsController);
        self.* = .{ .editor = editor, .on_will_change_hints = .init(editor.allocator) };
        errdefer self.dispose();
        try self.bind(services, options);
        try editor.registerOwnedContribution(InlayHintsController, self, dispose);
        return self;
    }
    fn bind(self: *InlayHintsController, services: Services, options: Options) !void {
        self.unbind();
        self.services = services;
        self.options = options;
        self.timer = .{ .queue = services.window, .context = self, .run = onDeadline };
        errdefer self.unbind();
        self.registry_listener = try services.registry.on_did_change.listen(self, onRegistry);
        self.scroll_listener = try self.editor.view_layout.onDidScroll().listen(self, onScroll);
        self.mouse_listener = try self.editor.on_did_mouse_event.listen(self, onMouse);
        self.will_change_listener = try self.editor.on_will_change_model.listen(self, onWillChange);
        self.did_change_listener = try self.editor.on_did_change_model.listen(self, onDidChange);
        try self.attachModel();
    }
    pub fn unbind(self: *InlayHintsController) void {
        self.detachModel();
        if (self.registry_listener) |id| self.services.?.registry.on_did_change.unlisten(id);
        if (self.scroll_listener) |id| self.editor.view_layout.onDidScroll().unlisten(id);
        if (self.mouse_listener) |id| self.editor.on_did_mouse_event.unlisten(id);
        if (self.will_change_listener) |id| self.editor.on_will_change_model.unlisten(id);
        if (self.did_change_listener) |id| self.editor.on_did_change_model.unlisten(id);
        self.registry_listener = null;
        self.scroll_listener = null;
        self.mouse_listener = null;
        self.will_change_listener = null;
        self.did_change_listener = null;
        self.timer.queue = null;
        self.services = null;
    }
    fn dispose(self: *InlayHintsController) void {
        self.unbind();
        self.on_will_change_hints.deinit();
        self.editor.allocator.destroy(self);
    }
    fn attachModel(self: *InlayHintsController) !void {
        if (!self.editor.hasModel()) return;
        self.model = self.editor.model;
        self.content_listener = try self.model.?.onDidChangeContentWithContextId(self, onContent);
        self.language_listener = try self.model.?.listenDidChangeLanguage(self, onLanguage);
        try self.rebind();
    }
    fn detachModel(self: *InlayHintsController) void {
        self.cancelPending();
        self.clearActive();
        self.unbindProviders();
        if (self.model) |model| {
            if (self.content_listener) |id| model.removeDidChangeContentListener(id);
            if (self.language_listener) |id| model.removeDidChangeLanguageListener(id);
        }
        self.content_listener = null;
        self.language_listener = null;
        self.model = null;
    }
    fn unbindProviders(self: *InlayHintsController) void {
        for (self.provider_listeners.items) |listener| listener.emitter.unlisten(listener.id);
        self.provider_listeners.deinit(self.editor.allocator);
        self.provider_listeners = .empty;
    }
    fn rebind(self: *InlayHintsController) !void {
        self.cancelPending();
        self.clearActive();
        self.unbindProviders();
        const model = self.model orelse return;
        const svc = self.services orelse return;
        const providers = try svc.registry.ordered(self.editor.allocator, model, false);
        defer self.editor.allocator.free(providers);
        for (providers) |provider| if (provider.on_did_change) |event| {
            const id = try event.listen(self, onProviderChanged);
            errdefer event.unlisten(id);
            try self.provider_listeners.append(self.editor.allocator, .{ .emitter = event, .id = id });
        };
        self.schedule();
    }
    pub fn configure(self: *InlayHintsController, options: Options, alt_link: bool) void {
        self.alt_link = alt_link;
        if (std.meta.eql(self.options, options)) return;
        self.options = options;
        self.rebind() catch {};
    }
    fn onWillChange(_: editor_common.IModelChangedEvent, self: *InlayHintsController) !void {
        self.detachModel();
    }
    fn onDidChange(_: editor_common.IModelChangedEvent, self: *InlayHintsController) !void {
        try self.attachModel();
    }
    fn onRegistry(_: usize, self: *InlayHintsController) !void {
        try self.rebind();
    }
    fn onLanguage(_: events.ModelLanguageChangedEvent, self: *InlayHintsController) !void {
        try self.rebind();
    }
    fn onProviderChanged(_: void, self: *InlayHintsController) !void {
        self.schedule();
    }
    fn onContent(_: events.InternalModelContentChangeEvent, self: *InlayHintsController) !void {
        // Existing decorations track the edit until fresh hints arrive;
        // their cached provider edits must no longer be invoked.
        self.cancelClick();
        self.on_will_change_hints.fire({}) catch {};
        self.schedule();
    }
    fn onScroll(event: ScrollEvent, self: *InlayHintsController) !void {
        if (event.scrollTopChanged or event.heightChanged) self.schedule();
    }
    fn visible(self: *const InlayHintsController) bool {
        return self.options.enabled == .on or self.options.enabled == .onUnlessPressed;
    }
    fn enabled(self: *InlayHintsController) bool {
        const svc = self.services orelse return false;
        const model = self.model orelse return false;
        return self.visible() and svc.registry.has(model);
    }
    fn cancelPending(self: *InlayHintsController) void {
        self.timer.schedule(null);
        if (self.pending) |request| request.deinit();
        self.pending = null;
    }
    fn schedule(self: *InlayHintsController) void {
        self.cancelPending();
        if (self.enabled()) self.timer.schedule(time.milliTimestamp() + 150);
    }
    fn onDeadline(context: *anyopaque, _: i64, _: bool) bool {
        const self: *InlayHintsController = @ptrCast(@alignCast(context));
        self.begin() catch {};
        return true;
    }
    fn begin(self: *InlayHintsController) !void {
        if (!self.enabled()) return;
        const model = self.model.?;
        const svc = self.services.?;
        const range = self.editor.visibleModelRange();
        const viewport = @max(1, range.endLineNumber -| range.startLineNumber);
        const first = @max(1, range.startLineNumber -| viewport);
        const last = @min(model.getLineCount(), range.endLineNumber +| viewport);
        const request = try Fragments.create(self.editor.allocator, svc.registry, model, .init(first, 1, last, model.getLineMaxColumn(last)), .{ .context = self, .complete = ready });
        self.pending = request;
        self.request_version = model.getVersionId();
        request.start();
    }
    fn ready(context: *anyopaque, request: *Fragments) void {
        const self: *InlayHintsController = @ptrCast(@alignCast(context));
        self.pending = null;
        if (self.model != request.model or request.model.getVersionId() != self.request_version) {
            request.deinit();
            return self.schedule();
        }
        self.clearActive();
        self.active = request;
        self.active_version = self.request_version;
        self.renderHints() catch self.clearActive();
    }
    fn clearActive(self: *InlayHintsController) void {
        self.cancelClick();
        self.last_click_part = null;
        if (self.active != null) self.on_will_change_hints.fire({}) catch {};
        if (self.model) |model| if (self.decorations.len > 0) {
            const empty = model.deltaDecorations(self.decorations, &.{}, 0) catch &.{};
            self.editor.allocator.free(empty);
        };
        self.editor.allocator.free(self.decorations);
        self.decorations = &.{};
        self.parts = &.{};
        if (self.active) |request| request.deinit();
        self.active = null;
    }
    fn appendDecoration(a: std.mem.Allocator, list: *std.ArrayList(model_types.ModelDeltaDecoration), item: *fragments.InlayHintItem, label: []const u8, class: ?[]const u8, data: ?*anyopaque, stop: model_types.InjectedTextCursorStops) !void {
        const options = try a.create(model_types.ModelDecorationOptions);
        options.* = .init("InlayHint", .AlwaysGrowsWhenTypingAtEdges);
        options.showIfCollapsed = item.anchor.range.isEmpty();
        options.collapseOnReplaceEdit = !item.anchor.range.isEmpty();
        const injected: model_types.InjectedTextOptions = .{ .content = label, .inlineClassName = class, .inlineClassNameAffectsLetterSpacing = false, .attachedData = data, .cursorStops = stop };
        if (item.anchor.direction == .before) options.before = injected else options.after = injected;
        try list.append(a, .{ .range = item.anchor.range, .options = options });
    }
    fn renderHints(self: *InlayHintsController) !void {
        const request = self.active orelse return;
        const a = request.arena.allocator();
        var decorations: std.ArrayList(model_types.ModelDeltaDecoration) = .empty;
        var parts: std.ArrayList(*Part) = .empty;
        var current_line: usize = 0;
        var length: usize = 0;
        for (request.items) |*item| {
            if (item.hint.position.lineNumber != current_line) {
                current_line = item.hint.position.lineNumber;
                length = 0;
            }
            if (self.options.maximum_length != 0 and length >= self.options.maximum_length) continue;
            const class = switch (item.hint.kind orelse @as(languages.InlayHintKind, .Type)) {
                .Type => if (item.hint.kind != null) styles.type_class else styles.hint_class,
                .Parameter => styles.parameter_class,
            };
            if (item.hint.padding_left) try appendDecoration(a, &decorations, item, " ", null, null, .None);
            if (self.options.padding) try appendDecoration(a, &decorations, item, " ", class, null, .None);
            for (item.hint.label, 0..) |part, index| {
                const label = try a.dupe(u8, part.label);
                for (label) |*byte| if (byte.* == '\n' or byte.* == '\r' or byte.* == '\t') {
                    byte.* = ' ';
                };
                const units = positions.utf16OffsetForColumn(label, label.len + 1) - 1;
                const shown = if (self.options.maximum_length != 0 and length + units > self.options.maximum_length) blk: {
                    const remaining = self.options.maximum_length -| length;
                    const cut = positions.columnForUtf16Offset(label, remaining) -| 1;
                    break :blk try std.fmt.allocPrint(a, "{s}…", .{label[0..cut]});
                } else label;
                length += units;
                const data = try a.create(Part);
                data.* = .{ .item = item, .index = index };
                try parts.append(a, data);
                const is_last = index + 1 == item.hint.label.len;
                try appendDecoration(a, &decorations, item, shown, class, data, if (is_last and !item.hint.padding_right and !self.options.padding) .Right else .None);
                if (self.options.maximum_length != 0 and length >= self.options.maximum_length) break;
            }
            if (self.options.padding) try appendDecoration(a, &decorations, item, " ", class, null, if (!item.hint.padding_right) .Right else .None);
            if (item.hint.padding_right) try appendDecoration(a, &decorations, item, " ", null, null, .Right);
        }
        self.parts = parts.items;
        self.decorations = try request.model.deltaDecorations(&.{}, decorations.items, 0);
    }
    pub fn partAt(self: *InlayHintsController, event: EditorMouseEvent) ?*Part {
        return self.partFromTarget(event.target);
    }
    pub fn partFromTarget(self: *InlayHintsController, target: @import("../../../browser/editorBrowser.zig").MouseTarget) ?*Part {
        const detail = target.detail orelse return null;
        if (detail != .content_text) return null;
        const text = detail.content_text.injected_text orelse return null;
        const data = text.options.attachedData orelse return null;
        for (self.parts) |part| if (@as(*anyopaque, @ptrCast(part)) == data) return part;
        return null;
    }
    pub fn partByIdentity(self: *InlayHintsController, identity: *const anyopaque) ?*Part {
        for (self.parts) |part| if (@as(*const anyopaque, @ptrCast(part)) == identity) return part;
        return null;
    }
    fn onMouse(event: EditorMouseEvent, self: *InlayHintsController) !void {
        const part = self.partAt(event) orelse {
            self.last_click_part = null;
            return;
        };
        if (event.event.button != .left) return;
        const modifier = if (self.alt_link) event.event.mods.alt else event.event.mods.ctrl;
        if (modifier) {
            if (event.event.kind == .down) {
                event.event.preventDefault();
                return;
            }
            if (event.event.kind == .up) {
                event.event.preventDefault();
                self.resolveClick(part, false);
            }
        } else if (event.event.kind == .up) {
            const now = time.milliTimestamp();
            if (self.last_click_part == part and now - self.last_click_ms <= 400) {
                self.last_click_part = null;
                self.resolveClick(part, true);
                event.event.preventDefault();
            } else {
                self.last_click_part = part;
                self.last_click_ms = now;
            }
        }
    }
    fn cancelClick(self: *InlayHintsController) void {
        if (self.click_pending) |pending| pending.dispose();
        self.click_pending = null;
        self.click_part = null;
    }
    fn resolveClick(self: *InlayHintsController, part: *Part, insert: bool) void {
        self.cancelClick();
        if (self.active == null or self.model == null or self.model.?.getVersionId() != self.active_version) return;
        self.click_part = part;
        self.click_insert = insert;
        if (!part.item.resolved) if (part.item.provider.resolve_inlay_hint) |resolve| {
            self.click_starting = true;
            const request = resolve(part.item.provider.context, self.active.?.arena.allocator(), self.model.?, part.item.hint, .{ .context = self, .complete = clickReady }) catch {
                self.click_starting = false;
                return self.cancelClick();
            };
            self.click_starting = false;
            if (self.inline_resolve) |reply| {
                self.inline_resolve = null;
                clickReady(self, reply);
            } else self.click_pending = request;
            return;
        };
        clickReady(self, part.item.hint);
    }
    fn clickReady(context: *anyopaque, result: anyerror!?languages.InlayHint) void {
        const self: *InlayHintsController = @ptrCast(@alignCast(context));
        if (self.click_starting) {
            self.inline_resolve = result;
            return;
        }
        self.click_pending = null;
        const part = self.click_part orelse return;
        self.click_part = null;
        if (result catch null) |hint| {
            part.item.hint = hint;
            part.item.resolved = true;
        }
        const services = self.services orelse return;
        if (self.click_insert) {
            locations.applyTextEdits(self.editor, part.item.hint.text_edits) catch {};
            self.schedule();
        } else if (part.index < part.item.hint.label.len) locations.openPart(self.editor.allocator, part.item.hint.label[part.index], services.opener, services.commands) catch {};
    }
};
