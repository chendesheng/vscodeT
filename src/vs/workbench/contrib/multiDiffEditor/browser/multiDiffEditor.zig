// Port of `src/vs/workbench/contrib/multiDiffEditor/browser/multiDiffEditor.ts`.
// This pane owns the multi-diff widget and retains its editor input. Session
// state is keyed by source URI/group using the shared editor memento.
const std = @import("std");
const ui = @import("ui");
const input_mod = @import("multiDiffEditorInput.zig");
const widget_mod = @import("../../../../editor/browser/widget/multiDiffEditor/multiDiffEditorWidget.zig");
const vm_mod = @import("../../../../editor/browser/widget/multiDiffEditor/multiDiffEditorViewModel.zig");
const scroll_mod = @import("../../../../editor/browser/widget/multiDiffEditor/compressedVirtualizedScrollView.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const Selection = @import("../../../../editor/common/core/selection.zig").Selection;
const ThemeColors = @import("../../../browser/themeColors.zig").ThemeColors;

pub const ID = "workbench.editor.multiDiffEditor";
pub fn MultiDiffEditor(comptime View: type) type {
    return struct {
        const Self = @This();
        pub const Widget = widget_mod.MultiDiffEditorWidget(View);
        pub const Host = Widget.Host;
        allocator: std.mem.Allocator,
        input: *input_mod.MultiDiffEditorInput,
        widget: *Widget,

        pub fn create(allocator: std.mem.Allocator, io: std.Io, input: *input_mod.MultiDiffEditorInput, window: *dispatch.Queue, host: Host, worker: ?vm_mod.WorkerServices, width: usize, height: usize, preserve_focus: bool) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const widget = try Widget.create(allocator, io, window, host, .noCardsNonCompact);
            errdefer widget.destroy();
            try widget.layout(width, height);
            const vm = try input.getViewModel(io, window, worker);
            try widget.setViewModel(vm, .{ .preserveFocus = preserve_focus });
            self.* = .{ .allocator = allocator, .input = input.retain(), .widget = widget };
            return self;
        }
        pub fn destroy(self: *Self) void {
            self.widget.destroy();
            self.input.destroy();
            self.allocator.destroy(self);
        }
        pub fn layout(self: *Self, width: usize, height: usize) void {
            self.widget.layout(width, height) catch {};
        }
        pub fn setThemeColors(self: *Self, palette: ?*const ThemeColors) void {
            self.widget.impl.setThemeColors(palette) catch {};
        }
        pub fn paint(self: *Self, frame: *ui.Frame, x: usize, y: usize, width: usize, height: usize) !void {
            try self.widget.paint(frame, x, y, width, height);
        }
        pub fn viewStateResource(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, self.input.source_uri);
        }
        const WireState = struct {
            scrollState: scroll_mod.ScrollPosition,
            docStates: []widget_mod.IMultiDiffDocState,
            activeDiffItemKey: ?[]u8 = null,
        };
        pub fn computeEditorViewState(self: *Self, allocator: std.mem.Allocator) ![]u8 {
            var state = try self.widget.getViewState(allocator);
            defer state.deinit();
            return std.json.Stringify.valueAlloc(allocator, WireState{ .scrollState = state.scrollState, .docStates = state.docStates, .activeDiffItemKey = state.activeDiffItemKey }, .{});
        }
        pub fn restoreEditorViewState(self: *Self, encoded: []const u8) !void {
            const parsed = try std.json.parseFromSlice(WireState, self.allocator, encoded, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            try self.widget.setViewState(.{ .allocator = self.allocator, .scrollState = parsed.value.scrollState, .docStates = parsed.value.docStates, .activeDiffItemKey = parsed.value.activeDiffItemKey });
        }
    };
}
