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
const common = @import("../common/multiDiffEditor.zig");
const event = @import("../../../../base/common/event.zig");
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const storage = @import("../../../../platform/storage/common/storage.zig");
const Workspace = @import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const editor_common = @import("../../../common/editor.zig");
const diff_common = @import("../../../../editor/common/multiDiffEditor.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const ListService = @import("../../../../platform/list/browser/listService.zig").ListService;

pub const ID = common.MULTI_DIFF_EDITOR_ID;
pub fn MultiDiffEditor(comptime View: type) type {
    return struct {
        const Self = @This();
        pub const Widget = widget_mod.MultiDiffEditorWidget(View);
        pub const Host = Widget.Host;
        pub const Composite = @import("multiDiffEditorWithFileListWidget.zig").MultiDiffEditorWithFileListWidget(View);
        pub const Settings = struct {
            configuration_service: configuration.IConfigurationService,
            storage_service: storage.IStorageService,
            workspace: ?*Workspace = null,
            lists: ?*ListService = null,
        };
        allocator: std.mem.Allocator,
        input: *input_mod.MultiDiffEditorInput,
        widget: *Widget,
        composite: ?*Composite = null,
        preferences: ?*common.Preferences = null,
        preferences_listener: ?event.SignalSubscription = null,
        widget_listener: ?event.SignalSubscription = null,
        active_control_listener: ?event.SignalSubscription = null,
        composite_listener: ?event.SignalSubscription = null,
        resolving_listener: ?event.SignalSubscription = null,
        pending_reveal: ?PendingReveal = null,
        changed: event.Emitter(void),

        const PendingReveal = struct {
            arena: std.heap.ArenaAllocator,
            data: diff_common.IMultiDiffEditorRevealData,
            fn deinit(self: *PendingReveal) void {
                self.arena.deinit();
            }
        };

        pub fn create(allocator: std.mem.Allocator, io: std.Io, input: *input_mod.MultiDiffEditorInput, window: *dispatch.Queue, host: Host, worker: ?vm_mod.WorkerServices, width: usize, height: usize, preserve_focus: bool, settings: ?Settings) !*Self {
            const preferences = if (settings) |services| try common.Preferences.create(allocator, services.configuration_service, services.storage_service) else null;
            var transferred = false;
            errdefer if (!transferred) if (preferences) |prefs| prefs.dispose();
            if (preferences) |prefs| if (prefs.available) try input.setResourceOrder(prefs.state.view_mode);
            const variant = if (preferences) |prefs| prefs.state.variant else common.defaultMultiDiffEditorExperimentalVariant;
            const composite = if (preferences != null and preferences.?.available) try Composite.create(allocator, io, window, host, variant, settings.?.storage_service, settings.?.workspace, settings.?.lists, preferences.?.state.enabled, preferences.?.state.view_mode, preferences.?.state.position) else null;
            const widget = if (composite) |value| value.widget else try Widget.create(allocator, io, window, host, variant);
            errdefer if (!transferred) {
                if (composite) |value| value.destroy() else widget.destroy();
            };
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .input = input.retain(), .widget = widget, .composite = composite, .preferences = preferences, .changed = event.Emitter(void).init(allocator) };
            transferred = true;
            errdefer self.destroy();
            if (composite) |value| try value.layoutWidget(width, height) else try widget.layout(width, height);
            const vm = try input.getViewModel(io, window, worker);
            if (composite) |value| try value.setViewModel(vm, preserve_focus) else try widget.setViewModel(vm, .{ .preserveFocus = preserve_focus });
            self.widget_listener = try widget.on_did_change_layout.listenDisposable(self, onChanged);
            self.active_control_listener = try widget.on_did_change_active_control.listenDisposable(self, onChanged);
            self.resolving_listener = try input.on_did_change_resolving_documents.listenDisposable(self, onChanged);
            if (composite) |value| self.composite_listener = try value.changed.listenDisposable(self, onChanged);
            if (preferences) |prefs| self.preferences_listener = try prefs.changed.listenDisposable(self, onPreferences);
            return self;
        }
        fn onChanged(_: void, self: *Self) !void {
            self.applyPendingReveal() catch |err| {
                if (err != error.DiffResourceNotFound) return err;
            };
            try self.changed.fire({});
        }
        fn cloneUri(a: std.mem.Allocator, value: ?std.Uri) !?std.Uri {
            return if (value) |uri| try std.Uri.parse(try std_uri.encodedResource(a, uri)) else null;
        }
        pub fn setOptions(self: *Self, options: editor_common.IMultiDiffEditorOptions) !void {
            self.widget.impl.preserve_focus_on_load = options.preserveFocus;
            const state = options.viewState orelse return;
            const reveal = state.revealData orelse return;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            var transferred = false;
            errdefer if (!transferred) arena.deinit();
            const a = arena.allocator();
            const pending: PendingReveal = .{
                .data = .{
                    .resource = .{ .original = try cloneUri(a, reveal.resource.original), .modified = try cloneUri(a, reveal.resource.modified) },
                    .range = reveal.range,
                },
                .arena = arena,
            };
            if (self.pending_reveal) |*previous| previous.deinit();
            self.pending_reveal = pending;
            transferred = true;
            try self.applyPendingReveal();
        }
        fn applyPendingReveal(self: *Self) !void {
            var pending = self.pending_reveal orelse return;
            self.pending_reveal = null;
            self.widget.reveal(pending.data.resource, pending.data.range) catch |err| {
                if (err == error.DiffResourceNotFound) {
                    const loading = if (self.widget.getViewModel()) |vm| vm.isLoading or !std.mem.eql(*vm_mod.DocumentDiffItemViewModel, vm.pending, vm.items) else true;
                    if (loading or self.input.isResolvingDocuments) {
                        self.pending_reveal = pending;
                        return;
                    }
                }
                pending.deinit();
                return err;
            };
            pending.deinit();
        }
        fn onPreferences(state: common.Preferences.State, self: *Self) !void {
            if (self.widget.impl.variant != state.variant) try self.widget.setVariant(state.variant);
            if (self.composite) |value| {
                try self.input.setResourceOrder(state.view_mode);
                try value.setPreferences(state.enabled, state.view_mode, state.position);
            }
            try self.changed.fire({});
        }
        pub fn detachServices(self: *Self) void {
            if (self.preferences_listener) |listener| listener.dispose();
            if (self.widget_listener) |listener| listener.dispose();
            if (self.active_control_listener) |listener| listener.dispose();
            self.active_control_listener = null;
            if (self.composite_listener) |listener| listener.dispose();
            if (self.resolving_listener) |listener| listener.dispose();
            self.resolving_listener = null;
            if (self.pending_reveal) |*pending| pending.deinit();
            self.pending_reveal = null;
            self.preferences_listener = null;
            self.widget_listener = null;
            self.composite_listener = null;
            if (self.composite) |value| value.detachFileList();
            if (self.preferences) |prefs| prefs.dispose();
            self.preferences = null;
        }
        pub fn destroy(self: *Self) void {
            self.detachServices();
            if (self.composite) |value| value.destroy() else self.widget.destroy();
            self.input.destroy();
            self.changed.deinit();
            self.allocator.destroy(self);
        }
        pub fn layout(self: *Self, width: usize, height: usize) void {
            if (self.composite) |value| value.layoutWidget(width, height) catch {} else self.widget.layout(width, height) catch {};
        }
        pub fn setWorkspace(self: *Self, workspace: ?*Workspace) !void {
            if (self.composite) |value| try value.setWorkspace(workspace);
        }
        pub fn setThemeColors(self: *Self, palette: ?*const ThemeColors) void {
            if (self.composite) |value| value.setThemeColors(palette) else self.widget.impl.setThemeColors(palette) catch {};
        }
        pub fn paint(self: *Self, frame: *ui.Frame, x: usize, y: usize, width: usize, height: usize) !void {
            if (self.composite) |value| try value.paint(frame, x, y, width, height) else try self.widget.paint(frame, x, y, width, height);
        }
        pub fn focus(self: *Self) !void {
            if (self.composite) |value| {
                try value.setFocused(true);
                try value.focusDiff();
            } else try self.widget.setFocused(true);
        }
        pub fn setFocused(self: *Self, focused: bool) !void {
            if (self.composite) |value| try value.setFocused(focused) else try self.widget.setFocused(focused);
        }
        pub fn focusFileList(self: *Self) !void {
            const value = self.composite orelse return;
            if (self.preferences) |prefs| {
                if (common.isFileListHidden(prefs.storage_service)) try common.toggleMultiDiffEditorFileList(prefs.storage_service);
            }
            try value.focusFileList();
        }
        pub fn fileListAvailable(self: *const Self) bool {
            return self.composite != null;
        }
        pub fn fileListEnabled(self: *const Self) bool {
            return if (self.composite) |value| value.enabled else false;
        }
        pub fn fileListVisible(self: *const Self) bool {
            return if (self.composite) |value| value.isFileListVisible else false;
        }
        pub fn fileListFocused(self: *const Self) bool {
            return if (self.composite) |value| value.isFileListFocused() else false;
        }
        pub fn fileListViewMode(self: *const Self) common.MultiDiffEditorFileListViewMode {
            return if (self.composite) |value| value.mode else .list;
        }
        pub fn fileListPosition(self: *const Self) common.MultiDiffEditorFileListPosition {
            return if (self.composite) |value| value.position else .right;
        }
        pub fn dispatchKey(self: *Self, input: *ui.KeyEvent) !bool {
            return if (self.composite) |value| value.dispatchKey(input) else self.widget.dispatchKey(input);
        }
        pub fn dispatchMouse(self: *Self, input: *ui.MouseEvent) !bool {
            return if (self.composite) |value| value.dispatchMouse(input) else self.widget.dispatchMouse(input);
        }
        pub fn pointerAt(self: *Self, x: usize, y: usize) !ui.Pointer {
            return if (self.composite) |value| value.pointerAt(x, y) else self.widget.pointerAt(x, y);
        }
        pub fn cursorCell(self: *Self) ?struct { row: usize, col: usize } {
            if (self.composite) |value| {
                const cell = value.cursorCell() orelse return null;
                return .{ .row = cell.row, .col = cell.col };
            }
            const cell = self.widget.cursorCell() orelse return null;
            return .{ .row = cell.row, .col = cell.col };
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
