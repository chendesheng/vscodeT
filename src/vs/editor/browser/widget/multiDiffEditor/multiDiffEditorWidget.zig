// Port of `src/vs/editor/browser/widget/multiDiffEditor/multiDiffEditorWidget.ts`.
// The implementation owns the compressed scroll layout and item templates;
// the facade exposes the same editor-local mode, model and view-state API.
const std = @import("std");
const ui = @import("ui");
const impl_mod = @import("multiDiffEditorWidgetImpl.zig");
const view_model = @import("multiDiffEditorViewModel.zig");
const model = @import("model.zig");
const options = @import("multiDiffEditorOptions.zig");
const common = @import("../../../common/multiDiffEditor.zig");
const Range = @import("../../../common/core/range.zig").Range;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const item_template = @import("diffEditorItemTemplate.zig");
const DiffWordWrap = @import("../diffEditor/diffEditorOptions.zig").DiffWordWrap;

pub const IMultiDiffEditorViewState = impl_mod.IMultiDiffEditorViewState;
pub const IMultiDiffDocState = impl_mod.IMultiDiffDocState;
pub const MultiDiffEditorViewModel = view_model.MultiDiffEditorViewModel;
pub const MultiDiffEditorVariant = options.MultiDiffEditorVariant;

pub fn MultiDiffEditorWidget(comptime View: type) type {
    return struct {
        const Self = @This();
        pub const Impl = impl_mod.MultiDiffEditorWidgetImpl(View);
        pub const Host = Impl.Host;
        pub const SetModelOptions = struct { preserveFocus: bool = false, viewState: ?IMultiDiffEditorViewState = null };
        impl: *Impl,
        allocator: std.mem.Allocator,
        on_did_change_layout: Emitter(void),
        on_will_dispose: Emitter(void),
        layout_listener: ?usize = null,

        pub fn create(allocator: std.mem.Allocator, io: std.Io, queue: *dispatch.Queue, host: Host, variant: MultiDiffEditorVariant) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .impl = try Impl.create(allocator, io, queue, host, variant), .on_did_change_layout = .init(allocator), .on_will_dispose = .init(allocator) };
            errdefer self.impl.destroy();
            errdefer self.on_did_change_layout.deinit();
            errdefer self.on_will_dispose.deinit();
            self.layout_listener = try self.impl.on_did_change_layout.listen(self, onLayoutChanged);
            return self;
        }
        pub fn destroy(self: *Self) void {
            self.on_will_dispose.fire({}) catch {};
            self.on_will_dispose.deinit();
            if (self.layout_listener) |id| self.impl.on_did_change_layout.unlisten(id);
            self.impl.destroy();
            self.on_did_change_layout.deinit();
            self.allocator.destroy(self);
        }
        fn onLayoutChanged(_: void, self: *Self) !void {
            try self.on_did_change_layout.fire({});
        }
        pub fn createViewModel(self: *Self, source: model.IMultiDiffEditorModel, worker: ?view_model.WorkerServices) !*MultiDiffEditorViewModel {
            return MultiDiffEditorViewModel.create(self.allocator, self.impl.io, source, self.impl.queue, worker);
        }
        pub fn setViewModel(self: *Self, source: ?*MultiDiffEditorViewModel, opts: SetModelOptions) !void {
            try self.impl.setViewModel(source, opts.preserveFocus, opts.viewState);
        }
        pub fn layout(self: *Self, width: usize, height: usize) !void {
            try self.impl.layout(width, height);
        }
        pub fn setVariant(self: *Self, variant: MultiDiffEditorVariant) !void {
            const old = self.impl;
            if (old.variant == variant) return;
            var state = try old.getViewState(self.allocator);
            defer state.deinit();
            const source = old.model;
            const focused = old.focused;
            const side = if (old.activeControl()) |editor| editor.focused else .modified;
            const replacement = try Impl.create(self.allocator, old.io, old.queue, old.host, variant);
            replacement.config.render_side_by_side = old.config.render_side_by_side;
            replacement.config.use_inline_when_limited = old.config.use_inline_when_limited;
            replacement.config.word_wrap = old.config.word_wrap;
            replacement.config.hide_original_line_numbers = old.config.hide_original_line_numbers;
            replacement.config.theme = old.config.theme;
            const width = old.scroll_view.width;
            const height = old.scroll_view.height;
            const padding = old.padding.height;
            if (self.layout_listener) |id| old.on_did_change_layout.unlisten(id);
            self.layout_listener = null;
            old.destroy();
            self.impl = replacement;
            self.layout_listener = try replacement.on_did_change_layout.listen(self, onLayoutChanged);
            try replacement.layout(width, height);
            try replacement.setPaddingBottom(padding);
            try replacement.setViewModel(source, true, state);
            if (focused) {
                if (replacement.activeControl()) |editor| editor.setFocus(side);
                try replacement.setFocused(true);
            }
            replacement.preserve_focus_on_load = false;
        }
        pub fn setRenderSideBySide(self: *Self, side_by_side: bool) !void {
            try self.impl.setRenderSideBySide(side_by_side);
        }
        pub fn setDiffLayoutOptions(self: *Self, mode: item_template.ViewMode, wrap: ?DiffWordWrap) !void {
            try self.impl.setDiffLayoutOptions(mode, wrap);
        }
        pub fn setPaddingBottom(self: *Self, height: usize) !void {
            try self.impl.setPaddingBottom(height);
        }
        pub fn getLayoutDebugState(self: *Self, allocator: std.mem.Allocator) !impl_mod.IMultiDiffEditorLayoutDebugState {
            return self.impl.getLayoutDebugState(allocator);
        }
        pub fn getViewState(self: *Self, allocator: std.mem.Allocator) !IMultiDiffEditorViewState {
            return self.impl.getViewState(allocator);
        }
        pub fn setViewState(self: *Self, state: IMultiDiffEditorViewState) !void {
            try self.impl.setViewState(state);
        }
        pub fn reveal(self: *Self, resource: common.IMultiDiffResourceId, range: ?Range) !void {
            try self.impl.reveal(resource, range);
        }
        pub fn getViewModel(self: *Self) ?*MultiDiffEditorViewModel {
            return self.impl.model;
        }
        pub fn activeControl(self: *Self) ?*Impl.Widget {
            return self.impl.activeControl();
        }
        pub fn goToNextChange(self: *Self) !void {
            try self.impl.goToNextChange();
        }
        pub fn goToPreviousChange(self: *Self) !void {
            try self.impl.goToPreviousChange();
        }
        pub fn collapseAll(self: *Self) !void {
            try self.impl.collapseAll();
        }
        pub fn expandAll(self: *Self) !void {
            try self.impl.expandAll();
        }
        pub fn setFocused(self: *Self, focused: bool) !void {
            try self.impl.setFocused(focused);
        }
        pub fn dispatchKey(self: *Self, event: *ui.KeyEvent) !bool {
            return self.impl.dispatchKey(event);
        }
        pub fn dispatchMouse(self: *Self, event: *ui.MouseEvent) !bool {
            return self.impl.dispatchMouse(event);
        }
        pub fn pointerAt(self: *Self, x: usize, y: usize) !ui.Pointer {
            return self.impl.pointerAt(x, y);
        }
        pub fn cursorCell(self: *Self) ?struct { row: usize, col: usize } {
            const cell = self.impl.cursorCell() orelse return null;
            return .{ .row = cell.row, .col = cell.col };
        }
        pub fn paint(self: *Self, frame: *ui.Frame, x: usize, y: usize, width: usize, height: usize) !void {
            try self.impl.paint(frame, x, y, width, height);
        }
    };
}
