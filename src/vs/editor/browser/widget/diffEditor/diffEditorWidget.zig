// Port of the terminal orchestration of
// `src/vs/editor/browser/widget/diffEditor/diffEditorWidget.ts`.
//
// Terminal adaptation: both editors retain their real resource models in every
// view mode. The shared ViewZones part aligns changes and wrapped/foreign-zone
// heights, and inserts the original's deleted code above modified lines in
// inline mode. The gutter uses vertical-layout offsets and the combined
// overview ruler reserves one cell per lane. True-inline text uses shared
// injected-text projection and the accessible viewer uses a retained cell view.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ui = @import("ui");
const sash_css = @import("../../../../base/browser/ui/sash/sash_css.zig");

const Editor = @import("../codeEditor/codeEditorWidgetTerminal.zig").Editor;
const EditorDocument = @import("../codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const TextEdit = @import("../codeEditor/codeEditorWidgetTerminal.zig").TextEdit;
const terminal_input = @import("../codeEditor/codeEditorWidgetTerminalInput.zig");
const diff_view_model = @import("./diffEditorViewModel.zig");
const diff_editor_options = @import("./diffEditorOptions.zig");
const diff_editor_editors = @import("./components/diffEditorEditors.zig");
const accessible_module = @import("./components/accessibleDiffViewer.zig");
const moved_feature = @import("./features/movedBlocksLinesFeature.zig");
const hide_unchanged_feature = @import("./features/hideUnchangedRegionsFeature.zig");
const gutter_feature = @import("./features/gutterFeature.zig");
const revert_feature = @import("./features/revertButtonsFeature.zig");
const overview_feature = @import("./features/overviewRulerFeature.zig");
const sash_mod = @import("./components/diffEditorSash.zig");
const view_model = diff_view_model;
const view_zones = @import("./components/diffEditorViewZones/diffEditorViewZones.zig");
const inline_margin = @import("./components/diffEditorViewZones/inlineDiffDeletedCodeMargin.zig");
const Clipboard = @import("../../../../platform/clipboard/common/clipboardService.zig").IClipboardService;
const ContextMenu = @import("../../../../platform/contextview/browser/contextMenuService.zig").IContextMenuService;
const decorations_mod = @import("./components/diffEditorDecorations.zig");
const Range = @import("../../../common/core/range.zig").Range;
const LineRange = @import("../../../common/core/ranges/lineRange.zig").LineRange;

pub const DiffEditorViewModel = diff_view_model.DiffEditorViewModel;
pub const DiffState = diff_view_model.DiffState;
pub const IDocumentDiff = diff_view_model.IDocumentDiff;
pub const DiffAlgorithmName = diff_editor_options.DiffAlgorithmName;
pub const DiffEditorDecorations = decorations_mod.DiffEditorDecorations;

pub const Options = diff_editor_options.Options;

pub const Side = enum { original, modified };

/// The upstream diff-editor context keys are derived from the current model,
/// display options and width layout, and notify title/menu consumers on change.
pub const ContextState = struct {
    has_changes: bool = false,
    inline_mode: bool = false,
    automatic_side_by_side: bool = false,
    temporary_inline_mode: bool = false,
    render_side_by_side: bool = true,
    auto_inline: bool = true,
    ignore_whitespace: bool = true,
    hide_unchanged: bool = false,
};

const Emitter = @import("../../../../base/common/event.zig").Emitter;

const window_dispatch = @import("../../../../base/common/windowDispatch.zig");
const SignalSubscription = @import("../../../../base/common/event.zig").SignalSubscription;
const milliTimestamp = @import("../../../../base/common/timeCompat.zig").milliTimestamp;

/// The widget's upstream width observer recognizes a smooth resize from a
/// captured pointer gesture or consecutive window resize events. The native
/// event queue replaces its 200 ms RunOnceScheduler; layout is still the
/// trigger for deciding the start width.
const SmoothResize = struct {
    start_width: ?usize = null,
    window_resize_count: usize = 0,
    was_pointer_driven: bool = false,
    pointer_down: bool = false,
    scheduler: window_dispatch.Task = .{},
    subscription: ?SignalSubscription = null,

    fn attach(self: *SmoothResize, queue: *window_dispatch.Queue) !void {
        if (self.scheduler.queue == queue) return;
        self.deinit();
        const emitter = if (queue.window_events) |*e| e else return;
        self.subscription = try emitter.listenDisposable(self, onWindowEvent);
        self.scheduler = .{ .queue = queue, .context = self, .run = finishScheduled };
    }

    fn deinit(self: *SmoothResize) void {
        self.scheduler.schedule(null);
        if (self.subscription) |subscription| subscription.dispose();
        self.* = .{};
    }

    fn schedule(self: *SmoothResize, now: i64) void {
        self.scheduler.schedule(now +| 200);
    }

    fn onWindowEvent(event: window_dispatch.WindowEvent, self: *SmoothResize) !void {
        switch (event) {
            .resize => {
                self.window_resize_count +|= 1;
                self.schedule(milliTimestamp());
            },
            .pointer_down => self.pointer_down = true,
            .pointer_up => {
                if (!self.pointer_down) return;
                self.pointer_down = false;
                self.scheduler.schedule(null);
                self.finish(milliTimestamp());
            },
        }
    }

    fn finish(self: *SmoothResize, now: i64) void {
        if (self.pointer_down) {
            self.schedule(now);
            return;
        }
        self.start_width = null;
        self.window_resize_count = 0;
        self.was_pointer_driven = false;
    }

    fn finishScheduled(context: *anyopaque, now: i64, _: bool) bool {
        const self: *SmoothResize = @ptrCast(@alignCast(context));
        self.finish(now);
        return false;
    }

    fn widthChanged(self: *SmoothResize, previous: usize, width: usize) ?usize {
        if (self.scheduler.queue == null or previous == 0 or previous == width) return null;
        if (self.start_width == null) self.start_width = previous;
        self.was_pointer_driven = self.was_pointer_driven or self.pointer_down;
        self.schedule(milliTimestamp());
        return if (self.was_pointer_driven or self.window_resize_count > 1) self.start_width else null;
    }
};

/// Terminal adapter type is supplied by the editor composition root. The
/// diff widget owns both editors and their upstream layout/selection flow.
const CodeEditorViewState = @import("../codeEditor/codeEditorWidgetTerminal.zig").ICodeEditorViewState;

pub const IDiffEditorViewState = struct {
    original: CodeEditorViewState,
    modified: CodeEditorViewState,
    modelState: ?DiffEditorViewModel.SerializedState = null,

    pub fn deinit(self: *IDiffEditorViewState, allocator: Allocator) void {
        self.original.deinit(allocator);
        self.modified.deinit(allocator);
        if (self.modelState) |*state| state.deinit(allocator);
        self.modelState = null;
    }
};

pub fn DiffEditorWidget(comptime View: type) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        io: Io,
        view_factory: *const fn (Allocator, *Editor) anyerror!*View,
        model_attached: bool = false,
        original_path: []u8,
        modified_path: []u8,
        original_label: []u8,
        modified_label: []u8,
        options: Options,
        accessibility_help_keybinding: ?[]u8 = null,
        inline_mode: bool = false,
        width_based_layout: diff_editor_options.WidthBasedLayout = .{},
        smooth_resize: SmoothResize = .{},

        view_model: *DiffEditorViewModel,
        owns_view_model: bool,
        zones: view_zones.DiffEditorViewZones = undefined,
        decorations: *DiffEditorDecorations,
        overview: overview_feature.OverviewRulerFeature = undefined,
        hide_unchanged: hide_unchanged_feature.HideUnchangedRegionsFeature = undefined,
        breadcrumbs_factory: ?hide_unchanged_feature.BreadcrumbsSourceFactory = null,
        original_scroll_anchor: ?hide_unchanged_feature.EditorScrollAnchor = null,
        modified_scroll_anchor: ?hide_unchanged_feature.EditorScrollAnchor = null,
        accessible_viewer: accessible_module.AccessibleDiffViewer,
        moved_blocks: moved_feature.MovedBlocksLinesFeature = undefined,
        inline_margin_menu: inline_margin.MenuController,
        gutter_toolbar: gutter_feature.DiffGutterToolbar = undefined,
        revert_buttons: revert_feature.RevertButtonsFeature = undefined,
        screen_x: usize = 0,
        screen_y: usize = 0,
        move_listener: ?usize = null,
        diff_listener: ?usize = null,
        context_state: ContextState = .{},
        on_did_change_model: Emitter(void),
        on_did_change_context: Emitter(void),
        on_did_change_focused_side: Emitter(Side),
        on_did_update_diff: Emitter(void),
        contributions: std.ArrayList(@import("../../editorExtensions.zig").DiffEditorContribution) = .empty,
        native_input_services: ?NativeInputServices = null,

        laying_out: bool = false,
        layout_pending: bool = false,

        original_editor: *Editor,
        modified_editor: *Editor,
        original_view: *View,
        modified_view: *View,

        sash_layout: sash_mod.SashLayout = .{},
        sash: sash_mod.DiffEditorSash = .{},
        focused: Side = .modified,
        current_change: ?usize = null,
        /// Keep the focused vertical position through a pane layout change.
        sync_top_line: bool = true,
        message: ?[]u8 = null,
        is_pasting: bool = false,
        width: usize = 0,
        height: usize = 0,

        pub const NativeInputServices = struct {
            context: *anyopaque,
            handle_key: *const fn (*anyopaque, *ui.KeyEvent) anyerror!bool,
            mouse_target: MouseTarget,
            set_theme: *const fn (*anyopaque, ?*const @import("../../../../workbench/browser/themeColors.zig").ThemeColors) void,
            attach_language: *const fn (*anyopaque, LanguageHost) void,
            dispose: *const fn (*anyopaque) void,
            pub const LanguageHost = struct {
                features: *@import("../../../common/services/languageFeaturesService.zig").LanguageFeaturesService,
                cache: ?*@import("../../../contrib/codelens/browser/codeLensCache.zig").CodeLensCache = null,
                commands: ?@import("../../../contrib/codelens/browser/codelensWidget.zig").CommandHost = null,
                window: *window_dispatch.Queue,
            };
        };

        pub fn interface(self: *Self) @import("../../editorBrowser.zig").IDiffEditor {
            return .{
                .context = self,
                .switch_side = CommandAdapter.call(switchSide),
                .exit_compare_move = CommandAdapter.call(exitCompareMove),
                .revert_focused = CommandAdapter.call(revertFocusedRangeMappings),
                .collapse_all = CommandAdapter.call(collapseAllUnchangedRegions),
                .show_all = CommandAdapter.call(showAllUnchangedRegions),
                .accessible_next = CommandAdapter.call(accessibleDiffViewerNext),
                .accessible_previous = CommandAdapter.call(accessibleDiffViewerPrev),
                .run_gutter_hunk = runGutterHunk,
                .on_did_update_diff = &self.on_did_update_diff,
                .get_computation_result = getDiffComputationResult,
                .get_modified_control = getModifiedControl,
                .get_max_computation_time = getMaxComputationTime,
                .focus_modified = focusModifiedControl,
                .set_accessibility_help_keybinding = setHelpKeybinding,
                .is_embedded = self.options.is_in_embedded_editor,
            };
        }

        fn setHelpKeybinding(context: *anyopaque, label: ?[]const u8) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            const copy = if (label) |value| try self.allocator.dupe(u8, value) else null;
            if (self.accessibility_help_keybinding) |old| self.allocator.free(old);
            self.accessibility_help_keybinding = copy;
            try self.updateAriaLabels();
        }

        fn updateAriaLabels(self: *Self) !void {
            if (!self.hasModel()) return;
            const label = try diff_editor_editors.updateAriaLabel(self.allocator, "Editor content", self.options.accessibility_verbose, self.accessibility_help_keybinding);
            defer self.allocator.free(label);
            try self.original_view.setAriaLabel(label);
            try self.modified_view.setAriaLabel(label);
        }

        fn focusModifiedControl(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.setFocus(.modified);
            self.modified_view.focusEditor();
            self.setEditorFocused(true);
        }

        fn getDiffComputationResult(context: *anyopaque) ?@import("../../editorBrowser.zig").DiffComputationResult {
            const self: *Self = @ptrCast(@alignCast(context));
            const value = self.state() orelse return null;
            return .{ .identical = value.identical, .quit_early = value.quit_early, .change_count = value.mappings.len };
        }

        fn getMaxComputationTime(context: *anyopaque) i64 {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.options.max_computation_time_ms;
        }

        fn getModifiedControl(context: *anyopaque) @import("../../editorBrowser.zig").ModifiedDiffControl {
            const self: *Self = @ptrCast(@alignCast(context));
            const Adapter = struct {
                fn add(ctx: *anyopaque, widget: @import("../../editorBrowser.zig").IOverlayWidget) !void {
                    const view: *View = @ptrCast(@alignCast(ctx));
                    try view.addOverlayWidget(widget);
                }
                fn remove(ctx: *anyopaque, id: []const u8) !void {
                    const view: *View = @ptrCast(@alignCast(ctx));
                    try view.removeOverlayWidget(id);
                }
                fn color(ctx: *anyopaque, id: []const u8, fallback: [3]u8) ui.Color {
                    const view: *View = @ptrCast(@alignCast(ctx));
                    return if (view.themeColors()) |palette| palette.color(id, fallback) else .{ .r = fallback[0], .g = fallback[1], .b = fallback[2] };
                }
                fn invalidate(ctx: *anyopaque) void {
                    const view: *View = @ptrCast(@alignCast(ctx));
                    view.invalidate();
                }
            };
            return .{ .editor = self.modified_editor, .overlays = .{ .context = self.modified_view, .add = Adapter.add, .remove = Adapter.remove, .color = Adapter.color, .invalidate = Adapter.invalidate } };
        }

        pub fn attachContributions(self: *Self, registrations: []const @import("../../editorExtensions.zig").DiffEditorContributionRegistration, accessor: @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor) !void {
            for (registrations) |registration| {
                for (self.contributions.items) |existing| {
                    if (std.mem.eql(u8, existing.id, registration.id)) break;
                } else {
                    if (try registration.create(self.allocator, self.interface(), accessor)) |contribution| {
                        errdefer contribution.dispose();
                        try self.contributions.append(self.allocator, contribution);
                    }
                }
            }
        }

        pub fn detachContributions(self: *Self) void {
            for (self.contributions.items) |contribution| contribution.dispose();
            self.contributions.clearRetainingCapacity();
        }

        fn runGutterHunk(context: *anyopaque, id: []const u8) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.focused != .modified) return;
            if (!try self.gutter_toolbar.runCurrentHunk(id)) self.modified_editor.setMessage("No hunk found at cursor position.", .{});
        }

        const CommandAdapter = struct {
            fn call(comptime command: fn (*Self) anyerror!void) *const fn (*anyopaque) anyerror!void {
                return struct {
                    fn run(context: *anyopaque) anyerror!void {
                        const widget: *Self = @ptrCast(@alignCast(context));
                        try command(widget);
                    }
                }.run;
            }
        };

        pub fn create(
            factory: *const fn (Allocator, *Editor) anyerror!*View,
            allocator: Allocator,
            io: Io,
            original_path: []const u8,
            modified_path: []const u8,
            original_text: []const u8,
            modified_text: []const u8,
            original_label: []const u8,
            modified_label: []const u8,
            width: usize,
            height: usize,
            options: Options,
        ) !*Self {
            return createWithDiff(factory, allocator, io, original_path, modified_path, original_text, modified_text, original_label, modified_label, width, height, options, null);
        }

        pub fn createWithDiff(
            factory: *const fn (Allocator, *Editor) anyerror!*View,
            allocator: Allocator,
            io: Io,
            original_path: []const u8,
            modified_path: []const u8,
            original_text: []const u8,
            modified_text: []const u8,
            original_label: []const u8,
            modified_label: []const u8,
            width: usize,
            height: usize,
            options: Options,
            computed: ?IDocumentDiff,
        ) !*Self {
            return createWithModelSources(factory, allocator, io, original_path, modified_path, original_text, modified_text, original_label, modified_label, width, height, options, .{}, computed);
        }

        /// Create independently owned inner editor views over resolved model
        /// sources. The documents remain owned by their inputs; a snapshot
        /// without a resolved model uses the provided immutable text.
        pub const ModelSources = struct {
            original: ?*EditorDocument = null,
            modified: ?*EditorDocument = null,
            /// A multi-diff item owns its model independently of a bound view.
            view_model: ?*DiffEditorViewModel = null,
        };

        pub fn createWithModelSources(
            factory: *const fn (Allocator, *Editor) anyerror!*View,
            allocator: Allocator,
            io: Io,
            original_path: []const u8,
            modified_path: []const u8,
            original_text: []const u8,
            modified_text: []const u8,
            original_label: []const u8,
            modified_label: []const u8,
            width: usize,
            height: usize,
            options: Options,
            sources: ModelSources,
            computed: ?IDocumentDiff,
        ) !*Self {
            const original_document = sources.original orelse try EditorDocument.createFromText(allocator, io, original_path, original_text, null);
            defer if (sources.original == null) original_document.release();
            const modified_document = sources.modified orelse try EditorDocument.createFromText(allocator, io, modified_path, modified_text, null);
            defer if (sources.modified == null) modified_document.release();
            const self = try createDetached(factory, allocator, io, width, height, options);
            errdefer self.destroy();
            try self.setDiffModel(.{
                .original = original_document,
                .modified = modified_document,
                .original_path = original_path,
                .modified_path = modified_path,
                .original_label = original_label,
                .modified_label = modified_label,
                .options = options,
                .width = width,
                .height = height,
                .view_model = sources.view_model,
                .computed = computed,
            });
            return self;
        }

        /// DiffEditorWidget owns its two CodeEditorWidgets independently of
        /// the currently attached diff model. The native View/feature
        /// registrations have the shorter model attachment lifetime.
        pub fn createDetached(
            factory: *const fn (Allocator, *Editor) anyerror!*View,
            allocator: Allocator,
            io: Io,
            width: usize,
            height: usize,
            options: Options,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const original = try Editor.createDetached(allocator, io, width, height, .{});
            errdefer destroyEditor(original);
            const modified = try Editor.createDetached(allocator, io, width, height, .{});
            self.* = .{
                .allocator = allocator,
                .io = io,
                .view_factory = factory,
                .original_path = &.{},
                .modified_path = &.{},
                .original_label = &.{},
                .modified_label = &.{},
                .options = options.normalize(),
                .view_model = undefined,
                .owns_view_model = false,
                .decorations = undefined,
                .on_did_change_model = .init(allocator),
                .on_did_change_context = .init(allocator),
                .on_did_change_focused_side = .init(allocator),
                .on_did_update_diff = .init(allocator),
                .accessible_viewer = accessible_module.AccessibleDiffViewer.init(allocator),
                .inline_margin_menu = .{ .allocator = allocator },
                .original_editor = original,
                .modified_editor = modified,
                .original_view = undefined,
                .modified_view = undefined,
                .width = @max(width, 1),
                .height = @max(height, 1),
            };
            return self;
        }

        pub const ModelBinding = struct {
            original: *EditorDocument,
            modified: *EditorDocument,
            original_path: []const u8,
            modified_path: []const u8,
            original_label: []const u8 = "Original",
            modified_label: []const u8 = "Modified",
            options: Options,
            width: usize,
            height: usize,
            view_model: ?*DiffEditorViewModel = null,
            computed: ?IDocumentDiff = null,
        };

        pub fn hasModel(self: *const Self) bool {
            return self.model_attached;
        }

        pub fn getViewModel(self: *const Self) ?*DiffEditorViewModel {
            return if (self.hasModel()) self.view_model else null;
        }

        pub fn setDiffModel(self: *Self, binding: ?ModelBinding) !void {
            const had_model = self.hasModel();
            if (binding) |value| {
                if (value.view_model) |vm| {
                    if (vm.model.original != value.original.model or vm.model.modified != value.modified.model) return error.DiffModelMismatch;
                    if (had_model and vm == self.view_model) return;
                }
                // The caller may refer to the outgoing documents and labels.
                // Keep them alive until the next attachment has taken ownership.
                value.original.retain();
                defer value.original.release();
                value.modified.retain();
                defer value.modified.release();
                var next = value;
                var scratch = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch.deinit();
                if (had_model) {
                    const a = scratch.allocator();
                    next.original_path = try a.dupe(u8, next.original_path);
                    next.modified_path = try a.dupe(u8, next.modified_path);
                    next.original_label = try a.dupe(u8, next.original_label);
                    next.modified_label = try a.dupe(u8, next.modified_label);
                }
                var retained = self.detachModel(next);
                self.attachModel(next, &retained) catch |err| {
                    retained.dispose();
                    self.original_editor.setModel(null) catch {};
                    self.modified_editor.setModel(null) catch {};
                    self.width_based_layout.resetWidthBasedLayout();
                    if (had_model) self.emitModelChanged();
                    return err;
                };
            } else {
                if (!had_model) return;
                _ = self.detachModel(null);
                self.on_did_change_context.fire({}) catch {};
            }
            self.emitModelChanged();
        }

        fn emitModelChanged(self: *Self) void {
            self.on_did_change_model.fire({}) catch {};
            self.on_did_update_diff.fire({}) catch {};
        }

        const RetainedViews = struct {
            original: ?*View = null,
            modified: ?*View = null,
            was_focused: bool = false,
            accessible_was_visible: bool = false,
            focus: Side = .modified,

            fn dispose(self: *RetainedViews) void {
                if (self.original) |view| view.deinit();
                if (self.modified) |view| view.deinit();
                self.* = .{};
            }
        };

        fn attachModel(self: *Self, binding: ModelBinding, retained: *RetainedViews) !void {
            std.debug.assert(!self.hasModel());
            const allocator = self.allocator;
            const options = binding.options;
            const normalized_options = options.normalize();
            const width = binding.width;
            const height = binding.height;
            const computed = binding.computed;
            const original_path_copy = try allocator.dupe(u8, binding.original_path);
            errdefer allocator.free(original_path_copy);
            const modified_path_copy = try allocator.dupe(u8, binding.modified_path);
            errdefer allocator.free(modified_path_copy);
            const original_label_copy = try allocator.dupe(u8, binding.original_label);
            errdefer allocator.free(original_label_copy);
            const modified_label_copy = try allocator.dupe(u8, binding.modified_label);
            errdefer allocator.free(modified_label_copy);
            const is_inline = !normalized_options.renderSideBySide(width);
            const original_editor = self.original_editor;
            const modified_editor = self.modified_editor;
            original_editor.setViewport(@max(width, 1), @max(height, 1));
            modified_editor.setViewport(@max(width, 1), @max(height, 1));
            try original_editor.setModel(binding.original);
            try modified_editor.setModel(binding.modified);

            const owns_view_model = binding.view_model == null;
            const diff_model = binding.view_model orelse try allocator.create(DiffEditorViewModel);
            if (owns_view_model) diff_model.* = DiffEditorViewModel.init(allocator, original_editor.model, modified_editor.model, computationOptions(normalized_options));
            errdefer if (owns_view_model) {
                diff_model.deinit();
                allocator.destroy(diff_model);
            };
            if (diff_model.model.original != original_editor.model or diff_model.model.modified != modified_editor.model) return error.DiffModelMismatch;
            if (owns_view_model) {
                if (computed) |result| try diff_model.applyComputedDiff(result) else try diff_model.compute();
            } else if (computed != null) return error.SharedDiffModelAlreadyComputed;
            const diff_state = diff_model.stateRef() orelse return error.DiffUnavailable;

            const reuse_modified_view = retained.modified != null;
            const original_view = retained.original orelse try self.view_factory(allocator, original_editor);
            retained.original = null;
            errdefer original_view.deinit();
            const modified_view = retained.modified orelse try self.view_factory(allocator, modified_editor);
            retained.modified = null;
            errdefer modified_view.deinit();

            original_editor.setReadOnly(!normalized_options.original_editable);
            modified_editor.setReadOnly(normalized_options.read_only);
            original_editor.setStatusRow(false);
            modified_editor.setStatusRow(false);
            original_editor.setLineDecorationsWidth(if (normalized_options.render_indicators) 1 else 0);
            modified_editor.setLineDecorationsWidth(if (normalized_options.render_indicators) 1 else 0);
            original_view.setStatusBarVisible(false) catch {};
            modified_view.setStatusBarVisible(false) catch {};
            original_editor.disableFolding();
            modified_editor.disableFolding();

            // The model decorations store pointers into the options structs owned
            // by `DiffEditorDecorations`, so it must live at a stable address
            // before the first update (a by-value field would be moved during the
            // struct assignment below).
            const decorations = try allocator.create(DiffEditorDecorations);
            errdefer allocator.destroy(decorations);
            decorations.* = DiffEditorDecorations.init(
                allocator,
                original_editor.model,
                modified_editor.model,
                1000,
                1001,
                .{
                    .render_indicators = options.render_indicators,
                    .show_empty_decorations = normalized_options.show_empty_decorations,
                    .use_true_inline_view = normalized_options.use_true_inline_view and is_inline,
                    // The diff owns its combined overview ruler, not the
                    // individual editors' decoration rulers.
                    .render_overview_ruler = false,
                },
            );
            errdefer decorations.deinit();
            try decorations.update(diff_state, normalized_options.show_moves and !is_inline);

            self.original_path = original_path_copy;
            self.modified_path = modified_path_copy;
            self.original_label = original_label_copy;
            self.modified_label = modified_label_copy;
            self.options = normalized_options;
            self.inline_mode = is_inline;
            self.focused = retained.focus;
            if (is_inline) self.focused = .modified;
            self.view_model = diff_model;
            self.owns_view_model = owns_view_model;
            self.decorations = decorations;
            self.original_view = original_view;
            self.modified_view = modified_view;
            self.model_attached = true;
            errdefer self.model_attached = false;
            self.gutter_toolbar = .{ .allocator = allocator, .model = self.view_model, .original = original_editor, .modified = modified_editor };
            errdefer self.gutter_toolbar.deinit();
            try self.view_model.initializeUnchangedRegions(normalized_options.hide_unchanged_regions, normalized_options.hide_unchanged_regions_minimum_line_count, normalized_options.hide_unchanged_regions_context_line_count);
            self.overview.init(allocator, original_editor, modified_editor);
            self.zones.init(allocator, original_editor, original_view.viewZones(), modified_editor, modified_view.viewZones(), modified_view.terminal_view_host, modified_view.lineStyleFunction(), modified_view.decorationBitsFunction(), normalized_options.render_indicators, self.state().?.mappings);
            errdefer self.zones.deinit();
            errdefer self.overview.deinit(original_editor, modified_editor);
            try self.hide_unchanged.init(allocator, self.view_model, &self.zones, original_editor, original_view.viewZones(), modified_editor, modified_view.viewZones(), normalized_options);
            errdefer self.hide_unchanged.deinit();
            if (self.smooth_resize.scheduler.queue) |window| self.hide_unchanged.attachWindow(window);
            try self.revert_buttons.init(allocator, self.view_model, modified_editor, modified_view.terminal_view_host, .{ .context = self, .revert = revertMarginChange });
            errdefer self.revert_buttons.deinit();
            try self.moved_blocks.init(allocator, self.view_model, &self.zones, original_editor, original_view.viewZones(), modified_editor, modified_view.viewZones(), self, onMoveWidthChanged, onCompareMove);
            errdefer self.moved_blocks.deinit();
            self.move_listener = try self.view_model.on_did_change_active_move.listen(self, onMoveStateChanged);
            errdefer self.view_model.on_did_change_active_move.unlisten(self.move_listener.?);
            self.diff_listener = try self.view_model.on_did_change.listen(self, onDiffStateChanged);
            errdefer self.view_model.on_did_change.unlisten(self.diff_listener.?);
            try self.view_model.startListening();
            // Keep the line views alive for layout changes and recomputation.
            self.layout(width, height);
            if (!reuse_modified_view) self.selectInitialChange();
            if (retained.was_focused) {
                self.focusedView().focusEditor();
                self.setEditorFocused(true);
            }
            errdefer self.accessible_viewer.close();
            if (normalized_options.only_show_accessible_diff_viewer or retained.accessible_was_visible) try self.accessibleDiffViewerNext();
            if (self.accessibility_help_keybinding != null) try self.updateAriaLabels();
            self.view_model.mounted_view_count += 1;
        }

        fn destroyEditor(editor: *Editor) void {
            const allocator = editor.allocator;
            editor.deinit();
            allocator.destroy(editor);
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            _ = self.detachModel(null);
            self.contributions.deinit(allocator);
            self.smooth_resize.deinit();
            self.on_did_change_model.deinit();
            self.on_did_change_context.deinit();
            self.on_did_change_focused_side.deinit();
            self.on_did_update_diff.deinit();
            destroyEditor(self.original_editor);
            destroyEditor(self.modified_editor);
            if (self.accessibility_help_keybinding) |key| allocator.free(key);
            allocator.destroy(self);
        }

        /// Dispose the model-specific bindings before detaching either
        /// CodeEditorWidget. An unbound template retains only widget-level
        /// state (options, event emitters and native resize subscription).
        fn detachModel(self: *Self, next: ?ModelBinding) RetainedViews {
            if (!self.hasModel()) return .{};
            const allocator = self.allocator;
            const retain_original = if (next) |binding| binding.original == self.original_editor.document else false;
            const retain_modified = if (next) |binding| binding.modified == self.modified_editor.document else false;
            const retained: RetainedViews = .{
                .original = if (retain_original) self.original_view else null,
                .modified = if (retain_modified) self.modified_view else null,
                .was_focused = if (next != null) self.focusedView().isFocused() else false,
                .accessible_was_visible = next != null and self.accessible_viewer.visible(),
                .focus = self.focused,
            };
            if (self.native_input_services) |services| {
                self.native_input_services = null;
                services.dispose(services.context);
            }
            self.detachContributions();
            self.gutter_toolbar.deinit();
            self.revert_buttons.deinit();
            self.accessible_viewer.close();
            self.inline_margin_menu.deinit();
            if (self.diff_listener) |id| self.view_model.on_did_change.unlisten(id);
            if (self.move_listener) |id| self.view_model.on_did_change_active_move.unlisten(id);
            self.diff_listener = null;
            self.move_listener = null;
            self.moved_blocks.deinit();
            self.detachBreadcrumbs();
            self.hide_unchanged.deinit();
            self.zones.deinit();
            self.overview.deinit(self.original_editor, self.modified_editor);
            self.decorations.deinit();
            allocator.destroy(self.decorations);
            self.view_model.mounted_view_count -= 1;
            if (self.owns_view_model) {
                self.view_model.deinit();
                allocator.destroy(self.view_model);
            }
            if (!retain_original) self.original_view.deinit();
            if (!retain_modified) self.modified_view.deinit();
            self.model_attached = false;
            if (next == null) {
                self.original_editor.setModel(null) catch {};
                self.modified_editor.setModel(null) catch {};
            }
            allocator.free(self.original_path);
            allocator.free(self.modified_path);
            allocator.free(self.original_label);
            allocator.free(self.modified_label);
            self.original_path = &.{};
            self.modified_path = &.{};
            self.original_label = &.{};
            self.modified_label = &.{};
            self.view_model = undefined;
            self.owns_view_model = false;
            self.original_scroll_anchor = null;
            self.modified_scroll_anchor = null;
            self.accessible_viewer.can_close = true;
            self.inline_margin_menu = .{ .allocator = allocator };
            self.focused = .modified;
            self.current_change = null;
            self.screen_x = 0;
            self.screen_y = 0;
            self.is_pasting = false;
            if (!retain_original or !retain_modified) self.width_based_layout.resetWidthBasedLayout();
            self.sash = .{};
            if (self.message) |message| allocator.free(message);
            self.message = null;
            self.context_state = .{};
            return retained;
        }

        fn computationOptions(options: Options) diff_view_model.Options {
            return .{
                .ignore_trim_whitespace = options.ignore_trim_whitespace,
                .max_computation_time_ms = options.max_computation_time_ms,
                .diff_algorithm = options.diff_algorithm,
                .show_moves = options.show_moves,
            };
        }

        pub fn updateOptions(self: *Self, raw_options: Options) !bool {
            return self.updateOptionsWithDiff(raw_options, null);
        }

        pub fn updateOptionsWithDiff(self: *Self, raw_options: Options, computed: ?IDocumentDiff) !bool {
            const options = raw_options.normalize();
            const old = self.options;
            if (std.meta.eql(old, options) and computed == null) return false;
            if (!self.hasModel()) {
                if (computed != null) return error.DiffUnavailable;
                self.width_based_layout.updateOptions(old, options);
                self.options = options;
                self.original_editor.setReadOnly(!options.original_editable);
                self.modified_editor.setReadOnly(options.read_only);
                return true;
            }
            const next_base = computationOptions(options);
            const needs_compute = !std.meta.eql(self.view_model.options, next_base);
            var result: ?IDocumentDiff = null;
            defer if (result) |*diff| @import("../../../common/diff/documentDiffProvider.zig").deinitDiff(self.allocator, diff);
            if (needs_compute and computed == null and self.view_model.worker == null) {
                var provider = @import("../../../common/diff/documentDiffProvider.zig").LineDiffProvider.init(next_base.diff_algorithm);
                result = try provider.interface().computeDiff(self.allocator, self.originalModel(), self.modifiedModel(), .{
                    .ignoreTrimWhitespace = next_base.ignore_trim_whitespace,
                    .maxComputationTimeMs = next_base.max_computation_time_ms,
                    .computeMoves = next_base.show_moves,
                }, .None);
            }
            self.width_based_layout.updateOptions(old, options);
            self.options = options;
            if (old.accessibility_verbose != options.accessibility_verbose) try self.updateAriaLabels();
            self.original_editor.setReadOnly(!options.original_editable);
            self.modified_editor.setReadOnly(options.read_only);
            if (old.read_only != options.read_only) try self.gutter_toolbar.refreshMenus();
            self.view_model.options = next_base;
            self.view_model.provider = @import("../../../common/diff/documentDiffProvider.zig").LineDiffProvider.init(next_base.diff_algorithm);
            self.original_editor.setLineDecorationsWidth(if (options.render_indicators) 1 else 0);
            self.modified_editor.setLineDecorationsWidth(if (options.render_indicators) 1 else 0);
            self.zones.setRenderIndicators(options.render_indicators);
            try self.hide_unchanged.updateOptions(options);
            const selected = if (computed) |diff| @as(?IDocumentDiff, diff) else result;
            if (selected) |diff| {
                try self.view_model.applyComputedDiff(diff);
            } else {
                if (needs_compute) self.view_model.requestRecompute(0);
                self.zones.beginBatch();
                defer self.zones.endBatch();
                if (old.hide_unchanged_regions != options.hide_unchanged_regions or old.hide_unchanged_regions_minimum_line_count != options.hide_unchanged_regions_minimum_line_count or old.hide_unchanged_regions_context_line_count != options.hide_unchanged_regions_context_line_count) {
                    try self.updateUnchangedRegions();
                }
                try self.updateDiffDecorations();
            }
            self.layout(self.width, self.height);
            if (options.only_show_accessible_diff_viewer and !self.accessible_viewer.visible()) try self.openAccessibleViewer();
            try self.accessible_viewer.setCanClose(!options.only_show_accessible_diff_viewer);
            return true;
        }

        fn updateUnchangedRegions(self: *Self) !void {
            try self.view_model.initializeUnchangedRegions(self.options.hide_unchanged_regions, self.options.hide_unchanged_regions_minimum_line_count, self.options.hide_unchanged_regions_context_line_count);
        }

        fn updateDiffDecorations(self: *Self) !void {
            var config = self.decorations.config;
            config.render_indicators = self.options.render_indicators;
            config.show_empty_decorations = self.options.show_empty_decorations;
            config.use_true_inline_view = self.options.use_true_inline_view and self.inline_mode;
            const show_moves = self.options.show_moves and self.sideBySide();
            const compare = if (show_moves) self.view_model.moved_text_to_compare else null;
            self.zones.setCompareMove(if (compare) |index| &self.state().?.moved_texts[index] else null, self.focused == .original);
            try self.decorations.setConfigWithMoveState(config, self.state().?, show_moves, self.view_model.activeMovedText(), compare);
            self.original_view.invalidate();
            self.modified_view.invalidate();
        }

        fn onDiffStateChanged(_: void, self: *Self) anyerror!void {
            self.zones.beginBatch();
            errdefer {
                self.zones.endBatch();
                self.layout(self.width, self.height);
            }
            const was_accessible = self.accessible_viewer.visible();
            self.accessible_viewer.close();
            const compare = self.view_model.moved_text_to_compare;
            try self.zones.replaceMappings(self.state().?.mappings);
            try self.moved_blocks.setEnabled(false);
            try self.updateUnchangedRegions();
            try self.updateDiffDecorations();
            try self.moved_blocks.setEnabled(self.options.show_moves and self.sideBySide());
            if (self.options.show_moves and self.sideBySide()) self.view_model.setMovedTextToCompare(compare);
            if (self.current_change) |index| {
                if (index >= self.changeCount()) self.current_change = if (self.changeCount() > 0) self.changeCount() - 1 else null;
            }
            self.overview.invalidate();
            try self.gutter_toolbar.updateSelection();
            try self.revert_buttons.update();
            if (was_accessible) try self.openAccessibleViewer();
            self.zones.endBatch();
            self.layout(self.width, self.height);
            self.on_did_update_diff.fire({}) catch {};
        }

        pub fn state(self: *const Self) ?*const DiffState {
            return if (self.hasModel()) self.view_model.stateRef() else null;
        }

        pub fn lineCount(self: *Self) usize {
            return self.modified_editor.viewLineCount();
        }

        pub fn sideBySide(self: *const Self) bool {
            return !self.inline_mode;
        }

        fn setInlineMode(self: *Self, inline_mode: bool) !void {
            if (self.inline_mode == inline_mode) return;
            self.inline_mode = inline_mode;
            if (inline_mode) {
                self.view_model.setMovedTextToCompare(null);
                self.view_model.setMovedTextFromCursor(null);
                self.setFocus(.modified);
                self.original_view.detach();
            }
            var config = self.decorations.config;
            config.use_true_inline_view = self.options.use_true_inline_view and inline_mode;
            try self.decorations.setConfig(config, self.state().?, self.options.show_moves and !inline_mode);
        }

        pub fn attachWindow(self: *Self, window: *window_dispatch.Queue) void {
            self.smooth_resize.attach(window) catch {};
            if (self.hasModel()) self.hide_unchanged.attachWindow(window);
        }

        pub fn layout(self: *Self, width: usize, height: usize) void {
            self.layoutWithResizeStart(width, height, null);
        }

        /// A host can pass the initial width of a continuous resize gesture.
        pub fn layoutWithResizeStart(self: *Self, width: usize, height: usize, smooth_resize_start_width: ?usize) void {
            if (!self.hasModel()) {
                self.width = @max(width, 1);
                self.height = @max(height, 1);
                return;
            }
            if (self.laying_out) {
                self.layout_pending = true;
                return;
            }
            self.laying_out = true;
            defer {
                self.laying_out = false;
                if (self.layout_pending) {
                    self.layout_pending = false;
                    self.layoutWithResizeStart(self.width, self.height, smooth_resize_start_width);
                }
            }
            self.zones.beginBatch();
            const smart_inline = self.isSimpleDiff();
            const resize_start = smooth_resize_start_width orelse self.smooth_resize.widthChanged(self.width, width);
            self.width_based_layout.setWidth(self.options, width, resize_start, false, smart_inline);
            const inline_mode = !self.width_based_layout.renderSideBySide(self.options, false, smart_inline);
            if (self.inline_mode != inline_mode) {
                self.setInlineMode(inline_mode) catch |err| {
                    self.modified_editor.setMessage("diff layout failed: {s}", .{@errorName(err)});
                };
            }
            self.hide_unchanged.setSideBySide(self.sideBySide());
            self.width = @max(width, 1);
            self.height = @max(height, 1);
            self.moved_blocks.setEnabled(self.options.show_moves and self.sideBySide()) catch {};
            self.revert_buttons.setEnabled(self.options.render_margin_revert_icon and self.sideBySide() and !self.options.read_only and !self.options.render_gutter_menu) catch {};
            self.moved_blocks.recomputeGeometry() catch {};
            diff_editor_editors.applyWordWrap(self.original_editor, self.modified_editor, self.options.diff_word_wrap, self.sideBySide());
            diff_editor_editors.applySubEditorOptions(self.original_view, self.modified_view, self.sideBySide(), self.options.hide_unchanged_regions or self.options.sticky_scroll_enabled == false, self.options.diff_code_lens);
            const widths = self.paneWidths();
            self.original_editor.setViewport(widths.original, self.height);
            self.modified_editor.setViewport(widths.modified, self.height);
            self.zones.use_true_inline_view = self.options.use_true_inline_view;
            self.zones.setMode(if (self.sideBySide()) .side_by_side else .inline_view);
            self.zones.endBatch();
            self.moved_blocks.recomputeGeometry() catch {};
            self.original_view.invalidate();
            self.modified_view.invalidate();
            self.overview.invalidate();
            self.accessible_viewer.layout(self.width, self.height) catch {};
            if (self.sync_top_line) self.syncTopLines();
            self.updateContextState(smart_inline);
        }

        fn updateContextState(self: *Self, smart_inline: bool) void {
            const next: ContextState = .{
                .has_changes = self.changeCount() > 0,
                .inline_mode = self.inline_mode,
                .automatic_side_by_side = self.width_based_layout.renderSideBySideInAutomaticMode(self.options, false, smart_inline),
                .temporary_inline_mode = self.width_based_layout.temporaryInlineMode(),
                .render_side_by_side = self.options.render_side_by_side,
                .auto_inline = self.options.use_inline_view_when_space_is_limited,
                .ignore_whitespace = self.options.ignore_trim_whitespace,
                .hide_unchanged = self.options.hide_unchanged_regions,
            };
            if (std.meta.eql(self.context_state, next)) return;
            self.context_state = next;
            self.on_did_change_context.fire({}) catch {};
        }

        fn isSimpleDiff(self: *const Self) bool {
            const state_ = self.state() orelse return false;
            for (state_.mappings) |mapping| {
                const change = mapping.line_range_mapping;
                if (!change.original.isEmpty() and !change.modified.isEmpty() and !(self.options.use_true_inline_view and view_zones.allowsTrueInlineDiffRendering(change))) return false;
            }
            return true;
        }

        pub fn resetWidthBasedLayout(self: *Self) void {
            self.width_based_layout.resetWidthBasedLayout();
            self.layout(self.width, self.height);
        }

        pub const PaneWidths = diff_editor_editors.PaneWidths;

        pub fn paneWidths(self: *const Self) PaneWidths {
            const overview = if (self.options.render_overview_ruler and self.width >= (if (self.sideBySide()) @as(usize, 3) else 1) + overview_feature.width) overview_feature.width else 0;
            const minimum: usize = if (self.sideBySide()) 3 else 1;
            const toolbar = if (self.options.render_gutter_menu and self.gutter_toolbar.hasActions() and self.width >= overview + minimum + gutter_feature.toolbar_width) gutter_feature.toolbar_width else 0;
            const moved_width = if (self.sideBySide()) @min(self.moved_blocks.width(), self.width -| overview -| toolbar -| 3) else 0;
            var result = diff_editor_editors.computePaneWidths(
                self.width - overview - moved_width - toolbar,
                self.sideBySide(),
                self.sash_layout.getRatio(self.options.split_view_default_ratio, self.options.enable_split_view_resizing),
                self.options.split_view_default_ratio,
                3,
            );
            if (!self.sideBySide() and !self.options.hide_original_line_numbers and !self.options.compact_mode) {
                // Inline mode retains the original editor up to decorationsLeft.
                // Clip to a whole number of cells and preserve one modified cell.
                result.original = @min(@max(@as(usize, 1), self.original_editor.gutterGlyphWidth() + self.original_editor.gutterNumberWidth()), result.modified -| 1);
                result.modified -= result.original;
            }
            result.overview = overview;
            result.moves = moved_width;
            result.toolbar = toolbar;
            return result;
        }

        /// Synchronize the two editors on the common vertical layout axis.
        pub fn syncTopLines(self: *Self) void {
            self.syncScrollFromPane(self.focused);
            self.original_view.invalidate();
            self.modified_view.invalidate();
        }

        pub fn saveViewState(self: *Self, allocator: Allocator) !IDiffEditorViewState {
            var original = try self.original_editor.saveViewState(allocator);
            errdefer original.deinit(allocator);
            var modified = try self.modified_editor.saveViewState(allocator);
            errdefer modified.deinit(allocator);
            return .{ .original = original, .modified = modified, .modelState = try self.view_model.serializeState(allocator) };
        }

        pub fn restoreViewState(self: *Self, saved: IDiffEditorViewState) !void {
            try self.original_editor.restoreViewState(saved.original);
            try self.modified_editor.restoreViewState(saved.modified);
            if (saved.modelState) |model_state| {
                try self.view_model.restoreSerializedState(model_state);
                // Collapsed view zones may have changed while restoring the
                // model state. Re-evaluate the saved model position against
                // the final layout rather than retaining a projected offset.
                self.original_editor.restoreScrollState(saved.original.viewState);
                self.modified_editor.restoreScrollState(saved.modified.viewState);
            }
            self.original_view.invalidate();
            self.modified_view.invalidate();
        }

        pub fn focusedEditor(self: *Self) *Editor {
            return if (self.focused == .original) self.original_editor else self.modified_editor;
        }

        pub fn focusedView(self: *Self) *View {
            return if (self.focused == .original) self.original_view else self.modified_view;
        }

        pub fn setFocus(self: *Self, side: Side) void {
            if (side == .original and !self.sideBySide()) return;
            if (self.focused == side) return;
            const was_focused = self.focusedView().isFocused();
            _ = self.focusedView().setFocused(false);
            self.focused = side;
            self.moved_blocks.setFocusedSide(side == .original);
            self.focusedView().focusEditor();
            if (was_focused) _ = self.focusedView().setFocused(true);
            self.on_did_change_focused_side.fire(side) catch {};
        }

        pub fn setEditorFocused(self: *Self, focused: bool) void {
            if (!self.hasModel()) return;
            _ = self.original_view.setFocused(focused and self.focused == .original and self.sideBySide());
            _ = self.modified_view.setFocused(focused and (self.focused == .modified or !self.sideBySide()));
        }

        pub fn syncScrollAfterInput(self: *Self) void {
            if (self.sideBySide()) self.syncScrollFromPane(self.focused);
        }

        fn selectInitialChange(self: *Self) void {
            const diff_state = self.state() orelse return;
            if (diff_state.mappings.len == 0) return;
            self.current_change = 0;
            self.revealChange(0);
        }

        pub fn changeCount(self: *const Self) usize {
            const diff_state = self.state() orelse return 0;
            return diff_state.mappings.len;
        }

        pub fn nextChange(self: *Self) bool {
            const count = self.changeCount();
            if (count == 0) return false;
            const cursor = self.modified_editor.modelCursorPosition().lineNumber;
            var next: usize = 0;
            for (0..count) |index| {
                if (self.changeStart(index) > cursor) {
                    next = index;
                    break;
                }
            }
            self.current_change = next;
            self.revealChange(next);
            return true;
        }

        pub fn previousChange(self: *Self) bool {
            const count = self.changeCount();
            if (count == 0) return false;
            const cursor = self.modified_editor.modelCursorPosition().lineNumber;
            var previous = count - 1;
            var index = count;
            while (index > 0) {
                index -= 1;
                if (self.changeStart(index) < cursor) {
                    previous = index;
                    break;
                }
            }
            self.current_change = previous;
            self.revealChange(previous);
            return true;
        }

        fn changeStart(self: *Self, index: usize) usize {
            return self.state().?.mappings[index].line_range_mapping.modified.startLineNumber;
        }

        fn revealChange(self: *Self, index: usize) void {
            if (index >= self.changeCount()) return;
            const row = self.changeStart(index);
            self.modified_editor.setCursorPosition(.{
                .lineNumber = @min(row, self.modified_editor.model.getLineCount()),
                .column = 1,
            }) catch {};
            const bounds = gutter_feature.hunkBounds(self.state().?.mappings[index].line_range_mapping, self.original_editor, self.modified_editor);
            const top = bounds.startLineNumber -| (self.height / 2);
            _ = self.modified_editor.setScrollTop(top);
            _ = self.original_editor.setScrollTop(top);
            self.original_view.invalidate();
            self.modified_view.invalidate();
        }

        pub fn swapSides(self: *Self) void {
            self.swapSidesInternal() catch |err| self.modified_editor.setMessage("swap diff failed: {s}", .{@errorName(err)});
        }

        fn swapSidesInternal(self: *Self) !void {
            if (!self.owns_view_model) return error.SharedDiffModelCannotSwap;
            self.inline_margin_menu.deinit();
            const was_focused = self.focusedView().isFocused();
            const accessible = self.accessible_viewer.visible();
            self.accessible_viewer.close();
            self.revert_buttons.deinit();
            self.moved_blocks.deinit();
            self.hide_unchanged.deinit();
            self.zones.deinit();
            self.decorations.detach();

            std.mem.swap(*Editor, &self.original_editor, &self.modified_editor);
            std.mem.swap(*View, &self.original_view, &self.modified_view);
            self.original_editor.setReadOnly(!self.options.original_editable);
            self.modified_editor.setReadOnly(self.options.read_only);
            std.mem.swap([]u8, &self.original_label, &self.modified_label);
            std.mem.swap([]u8, &self.original_path, &self.modified_path);
            self.view_model.swapModels();
            const diff_state = if (self.view_model.state) |*state_value| state_value else unreachable;
            for (diff_state.mappings) |*mapping| flipMapping(&mapping.line_range_mapping);
            for (diff_state.moved_texts) |*moved| {
                moved.lineRangeMapping = moved.lineRangeMapping.flip();
                for (@constCast(moved.changes)) |*change| flipMapping(change);
            }
            self.decorations.original_model = self.original_editor.model;
            self.decorations.modified_model = self.modified_editor.model;
            self.zones.init(self.allocator, self.original_editor, self.original_view.viewZones(), self.modified_editor, self.modified_view.viewZones(), self.modified_view.terminal_view_host, self.modified_view.lineStyleFunction(), self.modified_view.decorationBitsFunction(), self.options.render_indicators, diff_state.mappings);
            try self.hide_unchanged.init(self.allocator, self.view_model, &self.zones, self.original_editor, self.original_view.viewZones(), self.modified_editor, self.modified_view.viewZones(), self.options);
            if (self.smooth_resize.scheduler.queue) |window| self.hide_unchanged.attachWindow(window);
            self.hide_unchanged.setScrollAnchors(self.original_scroll_anchor, self.modified_scroll_anchor);
            if (self.breadcrumbs_factory) |factory| try self.hide_unchanged.attachBreadcrumbs(factory);
            try self.revert_buttons.init(self.allocator, self.view_model, self.modified_editor, self.modified_view.terminal_view_host, .{ .context = self, .revert = revertMarginChange });
            try self.moved_blocks.init(self.allocator, self.view_model, &self.zones, self.original_editor, self.original_view.viewZones(), self.modified_editor, self.modified_view.viewZones(), self, onMoveWidthChanged, onCompareMove);
            self.applyZoneTheme(self.modified_view.themeColors());
            self.focused = .modified;
            try onMoveStateChanged({}, self);
            _ = self.original_view.setFocused(false);
            _ = self.modified_view.setFocused(was_focused);
            if (was_focused) self.modified_view.focusEditor();
            if (self.inline_mode) self.original_view.detach();
            try self.gutter_toolbar.setEditors(self.original_editor, self.modified_editor);
            self.layout(self.width, self.height);
            if (self.current_change) |index| self.revealChange(index);
            if (accessible) try self.openAccessibleViewer();
            if (!self.view_model.is_diff_up_to_date) self.view_model.requestRecompute(0);
            self.on_did_update_diff.fire({}) catch {};
        }

        fn applyZoneTheme(self: *Self, palette: ?*const @import("../../../../workbench/browser/themeColors.zig").ThemeColors) void {
            if (palette) |colors| {
                self.zones.setColors(.{
                    .filler = colors.color("diffEditor.diagonalFill", .{ 40, 42, 44 }),
                    .removed_line = colors.color("diffEditor.removedLineBackground", .{ 75, 24, 24 }),
                    .removed_text = colors.color("diffEditor.removedTextBackground", .{ 92, 30, 30 }),
                    .indicator = colors.color("editorGutter.deletedBackground", .{ 158, 93, 80 }),
                });
            } else self.zones.setColors(.{});
        }

        pub fn attachNativeInputServices(self: *Self, services: NativeInputServices) void {
            if (self.native_input_services) |old| old.dispose(old.context);
            self.native_input_services = services;
            services.set_theme(services.context, self.modified_view.themeColors());
        }

        pub fn attachNativeLanguageServices(self: *Self, host: NativeInputServices.LanguageHost) void {
            if (self.native_input_services) |services| services.attach_language(services.context, host);
        }

        pub fn setThemeColors(self: *Self, palette: ?*const @import("../../../../workbench/browser/themeColors.zig").ThemeColors) void {
            if (!self.hasModel()) return;
            if (self.native_input_services) |services| services.set_theme(services.context, palette);
            self.original_view.setThemeColors(palette);
            self.modified_view.setThemeColors(palette);
            self.applyZoneTheme(palette);
            self.accessible_viewer.setTheme(palette) catch {};
        }

        pub fn mount(self: *Self, surface: *ui.Surface, container: *ui.Node, x: usize, y: usize) !void {
            self.screen_x = x;
            self.screen_y = y;
            if (self.accessible_viewer.visible()) {
                self.original_view.detach();
                self.modified_view.detach();
                return;
            }
            if (self.sideBySide()) {
                const widths = self.paneWidths();
                const offset = widths.modifiedLeft();
                try self.original_view.mountInto(surface, container, x, y, 0);
                try self.modified_view.mountInto(surface, container, x + offset, y, offset);
            } else {
                const widths = self.paneWidths();
                if (widths.original > 0) {
                    try self.original_view.mountInto(surface, container, x + widths.toolbar, y, widths.toolbar);
                } else self.original_view.detach();
                try self.modified_view.mountInto(surface, container, x + widths.modifiedLeft(), y, widths.modifiedLeft());
            }
        }

        /// Prepares both editor views and paints the center gutter.
        pub fn paint(self: *Self, frame: *ui.Frame, x: usize, y: usize, w: usize, h: usize) !void {
            self.screen_x = x;
            self.screen_y = y;
            if (w == 0 or h == 0) return;
            if (self.width != w or self.height != h) self.layout(w, h);
            if (self.accessible_viewer.visible()) {
                try self.accessible_viewer.paint(&frame.next, x, y);
                return;
            }
            const widths = self.paneWidths();

            if (self.sideBySide()) {
                try self.original_view.paint();
                if (!self.original_view.isMounted()) try ui.CellGrid.blit(&frame.next, self.original_view.grid(), x, y, widths.original, h);
                self.paintGutter(frame, x + widths.original, y, h);
                if (widths.moves > 0) {
                    const palette = self.modified_view.themeColors();
                    const normal = if (palette) |colors| colors.color("diffEditor.move.border", .{ 139, 139, 139 }) else ui.Color{ .r = 139, .g = 139, .b = 139 };
                    const active = if (palette) |colors| colors.color("diffEditor.moveActive.border", .{ 255, 165, 0 }) else ui.Color{ .r = 255, .g = 165, .b = 0 };
                    self.moved_blocks.paint(&frame.next, x + widths.original + widths.gutter, y, widths.moves, h, normal, active);
                }
                try self.modified_view.paint();
                if (!self.modified_view.isMounted()) try ui.CellGrid.blit(
                    &frame.next,
                    self.modified_view.grid(),
                    x + widths.modifiedLeft(),
                    y,
                    widths.modified,
                    h,
                );
            } else {
                if (widths.original > 0) {
                    try self.original_view.paint();
                    if (!self.original_view.isMounted()) try ui.CellGrid.blit(&frame.next, self.original_view.grid(), x + widths.toolbar, y, widths.original, h);
                }
                try self.modified_view.paint();
                if (!self.modified_view.isMounted()) try ui.CellGrid.blit(&frame.next, self.modified_view.grid(), x + widths.modifiedLeft(), y, widths.modified, h);
            }
            if (widths.toolbar > 0) {
                const palette = self.modified_view.themeColors();
                const normal = ui.cell.PaintStyle{ .fg = ui.cell.packColor(if (palette) |colors| colors.color("disabledForeground", .{ 110, 110, 110 }) else .{ .r = 110, .g = 110, .b = 110 }) };
                const active = ui.cell.PaintStyle{ .fg = ui.cell.packColor(if (palette) |colors| colors.foreground else .{ .r = 220, .g = 220, .b = 220 }) };
                self.gutter_toolbar.paint(&frame.next, x + widths.toolbarLeft(self.sideBySide()), y, widths.toolbar, h, normal, active);
            }
            if (widths.overview > 0) {
                try self.overview.prepareRender(
                    self.state().?.mappings,
                    self.original_editor,
                    self.modified_editor,
                    h,
                );
                const palette = self.modified_view.themeColors();
                const removed = if (palette) |colors| colors.color("diffEditorOverview.removedForeground", overview_feature.removed_foreground) else ui.Color{ .r = overview_feature.removed_foreground[0], .g = overview_feature.removed_foreground[1], .b = overview_feature.removed_foreground[2] };
                const inserted = if (palette) |colors| colors.color("diffEditorOverview.insertedForeground", overview_feature.inserted_foreground) else ui.Color{ .r = overview_feature.inserted_foreground[0], .g = overview_feature.inserted_foreground[1], .b = overview_feature.inserted_foreground[2] };
                const thumb = if (palette) |colors| colors.color("scrollbarSlider.background", .{ 60, 60, 60 }) else ui.Color{ .r = 60, .g = 60, .b = 60 };
                self.overview.paint(&frame.next, x + w - widths.overview, y, self.modified_editor, removed, inserted, thumb);
            }
        }

        /// The pointer shape under a pane-relative cell: text from the side that
        /// owns the cell, the split-view resize cursor over the center gutter.
        pub fn pointerAt(self: *Self, x: usize, y: usize) !ui.Pointer {
            if (self.accessible_viewer.visible()) return .default;
            const widths = self.paneWidths();
            if (widths.overview > 0 and x >= self.width - widths.overview) return .default;
            const toolbar_left = widths.toolbarLeft(self.sideBySide());
            if (x >= toolbar_left and x < toolbar_left + widths.toolbar) return self.gutter_toolbar.pointerAt(x - toolbar_left, y, self.height);
            if (self.sideBySide()) {
                if (x < widths.original) return self.original_view.pointerAt(x, y);
                if (x < widths.original + widths.gutter) return if (self.options.enable_split_view_resizing) sash_css.pointer(.vertical) else .default;
                if (x < widths.original + widths.gutter + widths.moves) return .default;
                return self.modified_view.pointerAt(x -| widths.modifiedLeft(), y);
            }
            if (x < widths.modifiedLeft()) return .default;
            const modified_x = x - widths.modifiedLeft();
            if (self.inline_margin_menu.available() and modified_x + 1 == self.modified_editor.gutterWidth() and (try self.zones.deletedAtViewportRow(y)) != null) return .pointer;
            return self.modified_view.pointerAt(modified_x, y);
        }

        pub fn attachActionServices(self: *Self, clipboard: Clipboard, menu: ContextMenu) void {
            self.inline_margin_menu.attach(clipboard, menu);
        }

        /// Upstream IDiffEditorWidgetOptions scroll-anchor callbacks.
        pub fn setScrollAnchors(self: *Self, original: ?hide_unchanged_feature.EditorScrollAnchor, modified: ?hide_unchanged_feature.EditorScrollAnchor) void {
            self.original_scroll_anchor = original;
            self.modified_scroll_anchor = modified;
            self.hide_unchanged.setScrollAnchors(original, modified);
        }

        pub fn attachBreadcrumbs(self: *Self, factory: hide_unchanged_feature.BreadcrumbsSourceFactory) !void {
            if (self.breadcrumbs_factory != null) {
                factory.dispose();
                return;
            }
            errdefer factory.dispose();
            try self.hide_unchanged.attachBreadcrumbs(factory);
            self.breadcrumbs_factory = factory;
        }

        pub fn detachBreadcrumbs(self: *Self) void {
            self.hide_unchanged.detachBreadcrumbs();
            if (self.breadcrumbs_factory) |factory| factory.dispose();
            self.breadcrumbs_factory = null;
        }

        pub fn attachGutterServices(self: *Self, menus: *@import("../../../../platform/actions/common/menuService.zig").MenuService, parent_context: @import("../../../../platform/contextkey/common/contextkey.zig").IContext, menu: ContextMenu) !void {
            try self.gutter_toolbar.attach(.{ .menus = menus, .parent_context = parent_context, .context_menu = menu, .context = self, .changed = onGutterChange });
        }

        pub fn detachGutterServices(self: *Self) void {
            self.gutter_toolbar.deinit();
        }

        fn onGutterChange(context: *anyopaque, layout_changed: bool) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (layout_changed) self.layout(self.width, self.height);
            self.modified_view.invalidate();
        }

        fn revertMarginChange(context: *anyopaque, change: revert_feature.RevertChange, original_version: u32, modified_version: u32) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.originalModel().getVersionId() != original_version or self.modifiedModel().getVersionId() != modified_version) return;
            switch (change) {
                .hunk => |mapping| try self.revert(mapping),
                .selection => |mappings| try self.revertRangeMappings(mappings),
            }
        }

        fn revertDeletedCode(context: *anyopaque, mapping: view_model.DetailedLineRangeMapping, original_version: u32, modified_version: u32) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.originalModel().getVersionId() != original_version or self.modifiedModel().getVersionId() != modified_version) return;
            try self.revert(mapping);
        }

        fn paintGutter(self: *Self, frame: *ui.Frame, x: usize, y: usize, height: usize) void {
            const palette = self.modified_view.themeColors();
            const normal = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(if (palette) |colors| colors.color("diffEditor.border", .{ 80, 80, 80 }) else .{ .r = 80, .g = 80, .b = 80 }),
            };
            const current = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(if (palette) |colors| colors.foreground else .{ .r = 220, .g = 220, .b = 220 }),
                .bg = ui.cell.packColor(if (palette) |colors| colors.color("editor.lineHighlightBackground", .{ 60, 60, 64 }) else .{ .r = 60, .g = 60, .b = 64 }),
            };
            const mappings = self.state().?.mappings;
            const cursor_line = self.focusedEditor().modelCursorPosition().lineNumber;
            const current_mapping = gutter_feature.mappingIndexAtModelLine(mappings, self.focused == .original, cursor_line) orelse self.current_change;
            const scroll_top = self.modified_editor.scrollTop();
            for (0..height) |row| frame.next.putCodepoint(x, y + row, '│', 1, normal);
            const provider: gutter_feature.DiffEditorGutter = .{ .mappings = mappings, .original = self.original_editor, .modified = self.modified_editor };
            var items = provider.render(scroll_top, height);
            while (items.next()) |item| {
                const style = if (current_mapping == item.index) current else normal;
                for (item.visible.startLineNumber..item.visible.endLineNumberExclusive) |offset| {
                    const glyph = if (offset == item.bounds.startLineNumber) gutter_feature.markerForMapping(mappings[item.index].line_range_mapping) else '│';
                    frame.next.putCodepoint(x, y + offset - scroll_top, glyph, 1, style);
                }
            }
        }

        pub fn cursorCell(self: *Self) ?struct { row: usize, col: usize } {
            if (self.accessible_viewer.visible()) return null;
            const widths = self.paneWidths();
            if (self.sideBySide() and self.focused == .original) {
                const cell = self.original_view.cursorCell() orelse return null;
                return .{ .row = cell.row, .col = cell.col };
            }
            const cell = self.modified_view.cursorCell() orelse return null;
            return .{ .row = cell.row, .col = cell.col + widths.modifiedLeft() };
        }

        /// Routes a key event to the focused inner editor.
        pub fn dispatchKey(self: *Self, event: *ui.KeyEvent) bool {
            if (self.accessible_viewer.visible()) return self.dispatchAccessibleKey(event);
            if (self.handleDeletedSelectionKey(event)) return true;
            if (self.native_input_services) |services| {
                const handled = services.handle_key(services.context, event) catch false;
                self.syncScrollAfterInput();
                return handled;
            }
            if (self.focusedView().dispatchKey(event)) return true;
            _ = terminal_input.dispatch(self.focusedEditor(), event.*, &self.is_pasting);
            if (self.sideBySide()) self.syncScrollFromPane(self.focused);
            return true;
        }

        /// A deleted-code zone has its own native selection, like the
        /// browser DOM range. Copy reads the original model, not the
        /// modified editor's unrelated cursor selection.
        pub fn handleDeletedSelectionKey(self: *Self, event: *ui.KeyEvent) bool {
            if (self.inline_margin_menu.clipboard) |clipboard| {
                if (event.mods.ctrl and event.key == .char and (event.key.char == 'c' or event.key.char == 'C')) {
                    if (self.zones.copyDeletedSelection(clipboard) catch false) return true;
                }
            }
            if (event.key == .escape and self.zones.clearDeletedSelection()) {
                self.modified_view.invalidate();
                return true;
            }
            return false;
        }

        /// Routes a mouse event to the correct pane, handles the split drag and
        /// keeps both panes aligned after a wheel scroll.
        pub const MouseTarget = struct {
            context: *anyopaque,
            dispatch: *const fn (*anyopaque, Side, *View, *ui.MouseEvent) anyerror!bool,
        };

        pub fn dispatchMouse(self: *Self, event: *ui.MouseEvent) !bool {
            return self.dispatchMouseWith(event, if (self.native_input_services) |services| services.mouse_target else null);
        }

        pub fn dispatchMouseWith(self: *Self, event: *ui.MouseEvent, target: ?MouseTarget) !bool {
            if (self.accessible_viewer.visible()) {
                if (event.kind == .down and event.button == .left) {
                    if (event.y == 0 and event.x >= self.width -| 3 and self.width >= 3 and self.accessible_viewer.can_close) {
                        self.closeAccessibleViewer(false);
                    } else {
                        try self.accessible_viewer.selectAtRow(event.y);
                        self.syncAccessibleSelection();
                    }
                    return true;
                }
                if (event.kind == .wheel) {
                    try self.accessible_viewer.scrollBy(event.delta_y);
                    return true;
                }
                return false;
            }
            if (self.hide_unchanged.dispatchDrag(event)) return true;
            defer if (event.kind == .down) self.hide_unchanged.captureDragStart(event.y);
            const widths = self.paneWidths();
            if (self.overview.drag != null or (widths.overview > 0 and event.x >= self.width - widths.overview and self.sash.drag == null)) {
                if (self.overview.dispatchMouse(self.modified_editor, event, self.height)) {
                    if (self.sideBySide()) self.syncScrollFromPane(.modified);
                    return true;
                }
                return false;
            }
            const toolbar_left = widths.toolbarLeft(self.sideBySide());
            const over_toolbar = widths.toolbar > 0 and event.x >= toolbar_left and event.x < toolbar_left + widths.toolbar;
            _ = self.gutter_toolbar.setHovered(over_toolbar);
            if (over_toolbar and self.sash.drag == null) {
                if (event.kind == .wheel) {
                    _ = self.modified_editor.setScrollTop(@intCast(@max(0, @as(i64, @intCast(self.modified_editor.scrollTop())) + event.delta_y)));
                    return true;
                }
                if (event.kind == .down) self.setFocus(.modified);
                return self.gutter_toolbar.dispatch(event, event.x - toolbar_left, self.height, .{ .x = self.screen_x + event.x, .y = self.screen_y + event.y });
            }
            if (event.kind == .up) self.gutter_toolbar.pressed = null;
            if (self.sideBySide() or self.sash.drag != null) {
                switch (self.sash.dispatchMouse(&self.sash_layout, event, widths.original, self.width -| widths.overview -| widths.gutter -| widths.moves -| widths.toolbar, self.sideBySide() and self.options.enable_split_view_resizing, @import("../../../../base/common/timeCompat.zig").milliTimestamp())) {
                    .changed => {
                        self.layout(self.width, self.height);
                        return true;
                    },
                    .handled => return true,
                    .none => {},
                }
            }

            if (self.sideBySide()) {
                if (event.x >= widths.original + widths.gutter and event.x < widths.original + widths.gutter + widths.moves) {
                    if (event.kind == .wheel) {
                        _ = self.modified_editor.setScrollTop(@intCast(@max(0, @as(i64, @intCast(self.modified_editor.scrollTop())) + event.delta_y)));
                        self.syncScrollFromPane(.modified);
                        return true;
                    }
                    return false;
                }
                const side: Side = if (event.x < widths.original) .original else .modified;
                if (event.kind == .down) self.setFocus(side);
                const view = if (side == .original) self.original_view else self.modified_view;
                var adjusted = event.*;
                if (side == .modified) adjusted.x -|= widths.modifiedLeft();
                if (adjusted.kind == .up and adjusted.x < view.editor.gutterGlyphWidth()) {
                    if (try self.dispatchFoldGlyph(side == .original, view, &adjusted)) return true;
                }
                const handled = if (target) |handler| try handler.dispatch(handler.context, side, view, &adjusted) else try view.dispatchMouse(&adjusted);
                self.syncScrollFromPane(side);
                return handled;
            }
            // The original editor remains mounted as a line-number margin. Its
            // content is clipped; wheel events use the modified viewport.
            if (event.x < widths.modifiedLeft() and event.kind != .wheel and !self.zones.draggingDeletedSelection()) {
                const changed = self.zones.updateDeletedHover(null);
                if (changed) self.modified_view.invalidate();
                return changed;
            }
            var adjusted = event.*;
            adjusted.x -|= widths.modifiedLeft();
            var hover_changed = false;
            if (self.inline_margin_menu.available() and (event.kind == .move or event.kind == .down or event.kind == .up)) {
                const mouse_target = try self.modified_view.mouseTargetAt(adjusted.x, event.y);
                const deleted = if (mouse_target.type == .content_view_zone or mouse_target.type == .gutter_view_zone) try self.zones.deletedAtViewportRow(event.y) else null;
                hover_changed = self.zones.updateDeletedHover(deleted);
                if (hover_changed) self.modified_view.invalidate();
                const gutter = self.modified_editor.gutterWidth();
                if (self.zones.draggingDeletedSelection() and (event.kind == .move or event.kind == .up)) {
                    if (deleted) |hit| if (try self.zones.extendDeletedSelection(hit, adjusted.x -| gutter)) self.modified_view.invalidate();
                    if (event.kind == .up) self.zones.finishDeletedSelection();
                    return true;
                }
                if (event.kind == .down and event.button == .left) {
                    if (deleted) |hit| {
                        if (mouse_target.type == .content_view_zone) {
                            self.setFocus(.modified);
                            try self.zones.beginDeletedSelection(hit, adjusted.x -| gutter);
                            self.modified_view.invalidate();
                            return true;
                        }
                    }
                    if (self.zones.clearDeletedSelection()) self.modified_view.invalidate();
                }
                if (deleted) |hit| {
                    if (event.kind == .down and event.button == .left and adjusted.x + 1 == gutter) {
                        self.setFocus(.modified);
                        return self.inline_margin_menu.show(self.originalModel(), self.modifiedModel(), hit.mapping, hit.line, !self.modified_editor.isReadOnly(), self.canRevert(), .{ .context = self, .run = revertDeletedCode }, .{ .x = self.screen_x + event.x, .y = self.screen_y + event.y, .opening_press = true });
                    }
                }
            }
            if (event.kind == .down) self.setFocus(.modified);
            if (event.kind == .up and adjusted.x < self.modified_editor.gutterGlyphWidth()) {
                if (try self.dispatchFoldGlyph(false, self.modified_view, &adjusted)) return true;
            }
            const handled = if (target) |handler| try handler.dispatch(handler.context, .modified, self.modified_view, &adjusted) else try self.modified_view.dispatchMouse(&adjusted);
            return handled or hover_changed;
        }

        fn dispatchFoldGlyph(self: *Self, original: bool, view: *View, event: *ui.MouseEvent) !bool {
            const mouse = try view.mouseTargetAt(event.x, event.y);
            if (mouse.type != .gutter_glyph_margin or event.x >= 3) return false;
            const position = mouse.position orelse return false;
            const slot = view.terminal_view_host.glyphMargin().renderedLine(position.lineNumber).lanes[event.x] orelse return false;
            if (slot.glyph.interactive or std.mem.indexOf(u8, slot.glyph.class_name, "fold-unchanged") == null) return false;
            return self.hide_unchanged.dispatchFoldGlyph(original, event, mouse);
        }

        fn onMoveWidthChanged(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.laying_out) {
                self.layout_pending = true;
            } else {
                self.layout(self.width, self.height);
            }
        }

        fn onCompareMove(context: *anyopaque, original: bool, index: usize) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.setFocus(if (original) .original else .modified);
            self.view_model.setMovedTextToCompare(if (self.view_model.moved_text_to_compare == index) null else index);
        }

        fn onMoveStateChanged(_: void, self: *Self) anyerror!void {
            const enabled = self.options.show_moves and self.sideBySide();
            const compare = if (enabled) self.view_model.moved_text_to_compare else null;
            self.zones.setCompareMove(if (compare) |index| &self.state().?.moved_texts[index] else null, self.focused == .original);
            try self.decorations.updateWithMoveState(self.state().?, enabled, self.view_model.activeMovedText(), compare);
            try self.revert_buttons.update();
            self.original_view.invalidate();
            self.modified_view.invalidate();
        }

        pub fn exitCompareMove(self: *Self) !void {
            self.view_model.setMovedTextToCompare(null);
        }

        pub fn mapToOtherSide(self: *Self) Range {
            const selection = self.focusedEditor().modelSelection();
            const flip = self.focused == .modified;
            const mappings = self.state().?.mappings;
            const utils = @import("./utils.zig");
            const first = utils.translatePosition(selection.getStartPosition(), mappings, flip);
            const last = utils.translatePosition(selection.getEndPosition(), mappings, flip);
            return Range.plusRange(&first, &last);
        }

        pub fn switchSide(self: *Self) !void {
            const selection = self.mapToOtherSide();
            const target_side: Side = if (self.focused == .modified) .original else .modified;
            const editor = if (target_side == .original) self.original_editor else self.modified_editor;
            self.setFocus(target_side);
            try editor.setSelection(editor.model.validateRange(selection));
        }

        fn canRevert(self: *Self) bool {
            return self.view_model.is_diff_up_to_date and !self.modified_editor.isReadOnly();
        }

        /// DiffEditorWidget.revert: the whole hunk is one undoable edit.
        pub fn revert(self: *Self, mapping: view_model.DetailedLineRangeMapping) !void {
            if (!self.canRevert()) return;
            try self.revertRangeMappings(&.{.{
                .originalRange = mapping.original.toExclusiveRange(),
                .modifiedRange = mapping.modified.toExclusiveRange(),
            }});
        }

        /// DiffEditorWidget.revertRangeMappings: collect the original text
        /// before applying edits, as the model event can replace the diff.
        pub fn revertRangeMappings(self: *Self, mappings: []const view_model.RangeMapping) !void {
            if (!self.canRevert() or mappings.len == 0) return;
            var edits: std.ArrayList(TextEdit) = .empty;
            defer {
                for (edits.items) |edit| self.originalModel().getAllocator().free(edit.text);
                edits.deinit(self.allocator);
            }
            try edits.ensureTotalCapacity(self.allocator, mappings.len);
            for (mappings) |mapping| {
                var text = try self.originalModel().getValueInRange(mapping.originalRange, null);
                errdefer text.deinit();
                edits.appendAssumeCapacity(.{
                    .range = self.modifiedModel().validateRange(mapping.modifiedRange),
                    .text = try text.toOwnedSlice(),
                });
            }
            self.modified_editor.beginUndoGroup();
            defer self.modified_editor.endUndoGroup();
            try self.modified_editor.applyTextEdits(edits.items, &.{});
        }

        pub fn revertFocusedRangeMappings(self: *Self) !void {
            if (!self.canRevert() or self.focused != .modified) return;
            const state_value = self.state() orelse return;
            const selection = self.modified_editor.modelSelection();
            const selected_range = LineRange.init(selection.startLineNumber, selection.endLineNumber);
            var mappings: std.ArrayList(view_model.RangeMapping) = .empty;
            defer mappings.deinit(self.allocator);
            for (state_value.mappings) |mapping| {
                const change = mapping.line_range_mapping;
                if (change.modified.intersect(selected_range) == null) continue;
                try mappings.append(self.allocator, .{
                    .originalRange = change.original.toExclusiveRange(),
                    .modifiedRange = change.modified.toExclusiveRange(),
                });
            }
            try self.revertRangeMappings(mappings.items);
        }

        pub fn collapseAllUnchangedRegions(self: *Self) !void {
            for (self.view_model.unchangedRegions()) |*region| region.collapseAll();
            try self.view_model.notifyUnchangedRegions();
        }

        pub fn showAllUnchangedRegions(self: *Self) !void {
            for (self.view_model.unchangedRegions()) |*region| region.showAll();
            try self.view_model.notifyUnchangedRegions();
        }

        fn openAccessibleViewer(self: *Self) !void {
            const paint_args: @import("./components/diffEditorViewZones/renderLines.zig").PaintOptions = .{
                .colors = .{ .line_background = .{ .r = 30, .g = 30, .b = 30 }, .text_background = .{ .r = 30, .g = 30, .b = 30 } },
                .style_fn = self.modified_view.lineStyleFunction(),
                .decoration_bits_fn = self.modified_view.decorationBitsFunction(),
            };
            try self.accessible_viewer.show(self.state().?.mappings, self.original_editor, self.modified_editor, self.width, self.height, !self.options.only_show_accessible_diff_viewer, paint_args, self.modified_view.themeColors());
            self.original_view.detach();
            self.modified_view.detach();
        }

        pub fn accessibleDiffViewerNext(self: *Self) !void {
            if (self.accessible_viewer.visible()) try self.accessible_viewer.nextGroup() else try self.openAccessibleViewer();
            self.syncAccessibleSelection();
        }

        pub fn accessibleDiffViewerPrev(self: *Self) !void {
            try self.openAccessibleViewer();
            try self.accessible_viewer.previousGroup();
            self.syncAccessibleSelection();
        }

        fn syncAccessibleSelection(self: *Self) void {
            const item = self.accessible_viewer.selectedLine() orelse return;
            if (item.type == .header) return;
            const line = item.modified_line_number orelse self.state().?.mappings[item.diff_index.?].line_range_mapping.modified.startLineNumber;
            const position = self.modified_editor.model.validatePosition(.{ .lineNumber = line, .column = 1 });
            self.modified_editor.setCursorPosition(position) catch {};
        }

        fn closeAccessibleViewer(self: *Self, reveal: bool) void {
            if (!self.accessible_viewer.can_close) return;
            const selected = self.accessible_viewer.selectedLine();
            self.accessible_viewer.close();
            self.setFocus(.modified);
            if (reveal) if (selected) |item| {
                if (item.type == .deleted and self.sideBySide()) {
                    self.setFocus(.original);
                    self.original_editor.setCursorPosition(.{ .lineNumber = item.original_line_number.?, .column = 1 }) catch {};
                } else self.syncAccessibleSelectionAfterClose(item);
            };
            self.focusedView().focusEditor();
            self.original_view.invalidate();
            self.modified_view.invalidate();
        }

        fn syncAccessibleSelectionAfterClose(self: *Self, item: accessible_module.ViewElement) void {
            if (item.type == .header) return;
            const line = item.modified_line_number orelse self.state().?.mappings[item.diff_index.?].line_range_mapping.modified.startLineNumber;
            self.modified_editor.setCursorPosition(self.modified_editor.model.validatePosition(.{ .lineNumber = line, .column = 1 })) catch {};
        }

        fn dispatchAccessibleKey(self: *Self, event: *ui.KeyEvent) bool {
            switch (event.key) {
                .up => self.accessible_viewer.moveLine(false) catch {},
                .down => self.accessible_viewer.moveLine(true) catch {},
                .escape => self.closeAccessibleViewer(false),
                .enter => self.closeAccessibleViewer(true),
                .char => |c| if (c == ' ') self.closeAccessibleViewer(true) else return false,
                .text => |text| if (std.mem.eql(u8, text, " ")) self.closeAccessibleViewer(true) else return false,
                else => return false,
            }
            if (self.accessible_viewer.visible()) self.syncAccessibleSelection();
            event.preventDefault();
            return true;
        }

        fn syncScrollFromPane(self: *Self, side: Side) void {
            const source = if (side == .original) self.original_editor else self.modified_editor;
            const other = if (side == .original) self.modified_editor else self.original_editor;
            const top = source.scrollTop();
            if (other.scrollTop() != top) _ = other.setScrollTop(top);
        }

        pub fn originalModel(self: *Self) *@import("../../../common/model/textModel.zig").TextModel {
            return self.original_editor.model;
        }

        pub fn modifiedModel(self: *Self) *@import("../../../common/model/textModel.zig").TextModel {
            return self.modified_editor.model;
        }
    };
}

fn flipMapping(mapping: *view_model.DetailedLineRangeMapping) void {
    std.mem.swap(LineRange, &mapping.original, &mapping.modified);
    if (mapping.inner_changes) |inner| {
        for (@constCast(inner)) |*change| {
            std.mem.swap(Range, &change.originalRange, &change.modifiedRange);
        }
    }
}
