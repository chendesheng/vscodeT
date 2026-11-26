// Port of the portable group-view behavior of
// `src/vs/workbench/browser/parts/editor/editorGroupView.ts`.
//
// The browser group view owns the DOM container, the title/tabs control, editor
// panes and lifecycle events. This port keeps the group's model-facing state:
// the ordered tab views for the model's editors, the active tab, the group's
// cell rectangle and the terminal tab-strip hit cache. The editor pane area is
// delegated to the ported `editorPanes.zig`.
//
// Terminal adaptation: the title control is the one-cell tab strip, and each
// tab owns a persistent editor view (the pane) instead of the browser reusing
// one pane per editor type. `Tab` is therefore a comptime parameter with these
// methods:
//
//   editorInput(self: *Tab) *EditorInput
//   layoutCells(self: *Tab, width: usize, height: usize) void
//   focusEditor(self: *Tab) void
//
// Upstream forwards `EditorPane.onDidFocus` through `EditorPanes` into
// `EditorGroupView.onDidFocus`; the terminal view has no DOM focus tracker, so
// `focus()` emits the group focus event directly after focusing the active
// pane. The part consumes that event the same way upstream does.
//
// Tab rendering and input handling live in `editorPane.zig`, and the
// tab-strip layout/paint in `multiEditorTabsControl.zig`; this file only
// decides which tab is associated with which model editor and how the group's
// views are laid out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const Emitter = @import("../../../../base/common/event.zig").Emitter;
const EditorGroupWatermark = @import("editorGroupWatermark.zig").EditorGroupWatermark;
const editorPanes = @import("editorPanes.zig");
const tab_bar = @import("multiEditorTabsControl.zig");
const title_mod = @import("editorTitleControl.zig");
const editor_groups = @import("../../../services/editor/common/editorGroupsService.zig");
const editor_input = @import("../../../common/editor/editorInput.zig");
const editor_mod = @import("../../../common/editor.zig");
const dialogs = @import("../../../../platform/dialogs/common/dialogs.zig");
const file_dialogs = @import("../../../services/dialogs/browser/abstractFileDialogService.zig");
const css = @import("../../../../editor/browser/editorCss.zig");

const EditorInput = editor_input.EditorInput;
const EditorsOrder = editor_mod.EditorsOrder;

pub const WatermarkShortcuts = struct {
    context: *anyopaque,
    render: *const fn (*anyopaque, *EditorGroupWatermark) anyerror!void,
};

/// Hit rectangle of one visible tab in the terminal tab strip. The browser
/// derives the same information from DOM tab elements.
pub const TabHit = struct {
    start: usize,
    end: usize,
    index: usize,
    /// The close/dirty cell, when the tab paints one.
    close_start: ?usize = null,
    close_end: ?usize = null,
};

/// One cell row is the terminal title control.
pub const title_height: usize = 1;
/// One cell row is the terminal breadcrumb bar (upstream `BreadcrumbsControl.HEIGHT`).
pub const breadcrumbs_height: usize = 1;

pub fn EditorGroupView(comptime View: type) type {
    comptime {
        if (@typeInfo(View) != .pointer) @compileError("Tab must be a pointer type");
    }

    return struct {
        const Self = @This();

        allocator: Allocator,
        group: *editor_groups.EditorGroup,
        tabs: std.array_list.Managed(View),
        hits: std.array_list.Managed(TabHit),
        title_action_hit: ?tab_bar.TitleActionHit = null,
        title_control: title_mod.EditorTitleControl,
        toolbar_hits: std.array_list.Managed(title_mod.ToolbarHit),
        rect: ui.Rect = .{},
        /// The workbench reserves a breadcrumb row when `breadcrumbs.enabled`.
        breadcrumbs_visible: bool = false,
        breadcrumbs_suppressed: bool = false,
        /// `workbench.editor.showTabs`: none/single can hide the title row.
        tabs_visible: bool = true,
        panes: editorPanes.EditorPanes(View) = .{},
        dom: ?GroupDom = null,
        watermark: ?EditorGroupWatermark = null,
        window: ?*@import("../../../../base/common/windowDispatch.zig").Queue = null,
        /// Upstream `EditorGroupView.onDidFocus`. The part listens to this to
        /// make a focused group the active group (`doSetGroupActive`).
        on_did_focus: Emitter(*Self),
        on_did_change_active_editor_pane: Emitter(?View),
        model_listener: ?usize = null,

        pub fn init(allocator: Allocator, group: *editor_groups.EditorGroup) Self {
            return .{
                .allocator = allocator,
                .group = group,
                .tabs = std.array_list.Managed(View).init(allocator),
                .hits = std.array_list.Managed(TabHit).init(allocator),
                .title_control = .{ .allocator = allocator },
                .toolbar_hits = .init(allocator),
                .on_did_focus = Emitter(*Self).init(allocator),
                .on_did_change_active_editor_pane = .init(allocator),
            };
        }

        pub fn attachTitleMenu(self: *Self, host: title_mod.Host) !void {
            try self.title_control.attach(host);
            if (comptime @hasField(@typeInfo(View).pointer.child, "diff")) {
                if (self.panes.activePane()) |tab| {
                    if (comptime @hasField(@typeInfo(View).pointer.child, "multi_diff")) {
                        if (tab.multi_diff) |multi| return self.title_control.setActiveMultiDiff(multi);
                    }
                    try self.title_control.setActiveDiff(if (tab.diff) |diff| diff.widget else null);
                } else try self.title_control.setActiveDiff(null);
            }
        }

        pub fn disposeEditorMenus(self: *Self) void {
            self.title_control.deinit();
            if (comptime @hasDecl(@typeInfo(View).pointer.child, "detachDiffGutterServices")) {
                for (self.tabs.items) |tab| tab.detachDiffGutterServices();
            }
        }

        pub fn registerModelListeners(self: *Self) !void {
            self.model_listener = try self.group.model.on_did_model_change.listen(self, onDidModelChange);
        }

        pub fn disposeModelListeners(self: *Self) void {
            if (self.model_listener) |id| self.group.model.on_did_model_change.unlisten(id);
            self.model_listener = null;
        }

        fn onDidModelChange(event: @import("../../../common/editor/editorGroupModel.zig").GroupModelChangeEvent, self: *Self) !void {
            switch (event) {
                .EDITOR_DIRTY => |change| try self.onDidChangeEditorDirty(change.editor),
                else => {},
            }
        }

        // Upstream always pins a dirty editor. The title control reads the
        // group's model when it paints; it does not need a separate scan.
        fn onDidChangeEditorDirty(self: *Self, input: *@import("../../../common/editor/editorInput.zig").EditorInput) !void {
            _ = try self.group.model.pin(input);
        }

        /// Disposes the tab views, like upstream `EditorGroupView.dispose()`
        /// disposing the group's editors, then frees the registries.
        pub fn deinit(self: *Self) void {
            self.disposeModelListeners();
            self.title_control.deinit();
            self.toolbar_hits.deinit();
            if (self.dom) |dom| {
                // A tab can already belong to another group before its editor
                // instance is moved to the new group's container.
                if (dom.editor_container.first_child) |child| _ = dom.editor_container.removeChild(child);
                dom.split_view.document.destroy(dom.split_view);
            }
            for (self.tabs.items) |tab| tab.deinit();
            self.panes.clearActive();
            self.on_did_focus.deinit();
            self.on_did_change_active_editor_pane.deinit();
            self.hits.deinit();
            self.tabs.deinit();
        }

        fn layoutDom(self: *Self, grid: *ui.Node, part_bounds: ui.Rect, visible: bool) !void {
            if (self.dom == null) self.dom = try GroupDom.create(grid);
            const dom = self.dom.?;
            if (visible) {
                if (dom.split_view.hasClass(css.splitview.Class.hidden_view)) {
                    dom.split_view.removeClass(css.splitview.Class.hidden_view);
                }
            } else {
                try dom.split_view.addClass(css.splitview.Class.hidden_view);
                return;
            }
            const chrome: f64 = @floatFromInt(self.chromeHeight());
            setStyleIfChanged(dom.split_view, .{
                .left = .{ .cells = self.rect.x - part_bounds.x },
                .top = .{ .cells = self.rect.y - part_bounds.y },
                .width = .{ .cells = self.rect.w },
                .height = .{ .cells = self.rect.h },
            });
            setStyleIfChanged(dom.title, .{ .height = .{ .cells = chrome } });
            setStyleIfChanged(dom.editor_container, .{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = chrome },
                .width = .{ .percent = 100 },
                .height = .{ .cells = @max(0, self.rect.h - chrome) },
            });
            if (self.activeTab() == null) {
                try dom.editor_container.addClass(css.editor_group.Class.empty_editor_container);
            } else if (dom.editor_container.hasClass(css.editor_group.Class.empty_editor_container)) {
                dom.editor_container.removeClass(css.editor_group.Class.empty_editor_container);
            }
        }

        /// Layout and mount the active editor pane into its group container.
        pub fn layoutEditorArea(
            self: *Self,
            grid: *ui.Node,
            part_bounds: ui.Rect,
            surface: *ui.Surface,
            visible: bool,
            show_tips: bool,
            colors: @import("editorGroupWatermark.zig").Colors,
            shortcuts: WatermarkShortcuts,
        ) !void {
            const active = self.activeTab();
            if (self.updateBreadcrumbsVisibility()) self.layout();
            try self.layoutDom(grid, part_bounds, visible);
            if (!visible) return;
            const container = self.dom.?.editor_container;
            const width = ui.cell.snap(self.rect.w);
            const group_height = ui.cell.snap(self.rect.h);
            const height = group_height -| self.chromeHeight();
            if (self.isEmpty() and self.watermark == null) {
                self.watermark = try EditorGroupWatermark.init(self.dom.?.group);
            }
            if (self.watermark) |*watermark| {
                if (self.isEmpty() and show_tips and watermark.shortcuts == null) try shortcuts.render(shortcuts.context, watermark);
                watermark.layout(width, group_height, self.isEmpty(), show_tips, colors);
            }
            if (active) |tab| {
                if (width == 0 or height == 0) return;
                try tab.mount(
                    surface,
                    container,
                    ui.cell.snap(self.rect.x),
                    ui.cell.snap(self.rect.y) + self.chromeHeight(),
                    width,
                    height,
                );
            } else if (container.first_child) |child| {
                _ = container.removeChild(child);
            }
        }

        pub fn count(self: *const Self) usize {
            return self.tabs.items.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.tabs.items.len == 0;
        }

        /// Upstream `get activeEditor`.
        pub fn activeEditor(self: *const Self) ?*EditorInput {
            return self.group.model.activeEditor();
        }

        /// Upstream `get activeEditorPane`, adapted to the tab's persistent view.
        pub fn activeTab(self: *const Self) ?View {
            const active = self.activeEditor() orelse return null;
            return self.tabForInput(active);
        }

        pub fn tabForInput(self: *const Self, input: *EditorInput) ?View {
            for (self.tabs.items) |tab| {
                if (tab.editorInput() == input) return tab;
            }
            return null;
        }

        pub fn indexOfTab(self: *const Self, tab: View) ?usize {
            for (self.tabs.items, 0..) |candidate, index| {
                if (candidate == tab) return index;
            }
            return null;
        }

        /// Upstream `getEditors(EditorsOrder.SEQUENTIAL)` projected onto the
        /// tab views.
        pub fn orderedTabs(
            self: *const Self,
            allocator: Allocator,
            out: *std.array_list.Managed(View),
        ) !void {
            const editors = try self.group.model.getEditors(allocator, .SEQUENTIAL, false);
            defer allocator.free(editors);
            for (editors) |input| {
                if (self.tabForInput(input)) |tab| try out.append(tab);
            }
        }

        /// Index of the active tab in `ordered`.
        pub fn activeIndex(self: *const Self, ordered: []const View) usize {
            const active = self.activeEditor() orelse return 0;
            for (ordered, 0..) |tab, index| {
                if (tab.editorInput() == active) return index;
            }
            return 0;
        }

        /// The tab at model order `index`.
        pub fn tabAtIndex(self: *const Self, allocator: Allocator, index: usize) ?View {
            var ordered = std.array_list.Managed(View).init(allocator);
            defer ordered.deinit();
            self.orderedTabs(allocator, &ordered) catch return null;
            if (index >= ordered.items.len) return null;
            return ordered.items[index];
        }

        /// Upstream restores the active pane and passes all editors to the title
        /// control. Terminal groups retain one tab view per supported input.
        pub fn restoreEditors(self: *Self, panes: anytype) !void {
            const editors = try self.group.model.getEditors(self.allocator, .SEQUENTIAL, false);
            defer self.allocator.free(editors);
            try self.tabs.ensureUnusedCapacity(editors.len);
            for (editors) |input| {
                const tab = try panes.createPane(self.allocator, input) orelse continue;
                try self.addTab(tab);
                try panes.didRestore(tab, self.group.id);
            }
        }

        /// Registers the view for an input that is already in the group model.
        /// A new active editor becomes the visible pane right away.
        pub fn attachWindow(self: *Self, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
            self.window = window;
            if (@hasDecl(@typeInfo(View).pointer.child, "attachWindow")) for (self.tabs.items) |tab| tab.attachWindow(window);
        }

        pub const CopyEditorHost = struct {
            context: *anyopaque,
            view_factory: @import("editorPane.zig").EditorViewFactory,
            io: std.Io,
            async_io: std.Io,
            images: *ui.image.Runtime,
            window: *@import("../../../../base/common/windowDispatch.zig").Queue,
            configure: *const fn (*anyopaque, View) void,
            discard: *const fn (*anyopaque, View) void,
            create_terminal: *const fn (*anyopaque, *Self, *@import("../../../contrib/terminal/browser/terminalInstance.zig").TerminalInstance) anyerror!View,
        };

        /// Upstream copyEditor/doMoveOrCopyEditorAcrossGroups, adapted to the
        /// target's persistent editor views. The terminal editor copy retains
        /// the source document while creating a new independent view.
        pub fn copyEditor(self: *Self, tab: View, options: @import("../../../common/editor/editorGroupModel.zig").EditorOpenOptions, host: CopyEditorHost) !View {
            const TabType = @typeInfo(View).pointer.child;
            const ImagePreviewEditorInput = @import("../../../contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInput;
            if (tab.terminalInstance()) |parent| {
                const copy = try host.create_terminal(host.context, self, parent);
                if (options.index) |index| _ = try self.group.model.moveEditor(copy.input, index);
                if (options.sticky) _ = try self.group.model.stick(copy.input);
                return copy;
            }
            if (tab.file_input) |file_input| {
                const copied_input = try file_input.copyInput();
                var input_owned = true;
                errdefer if (input_owned) copied_input.deinit();
                var tab_owned: ?View = null;
                errdefer if (tab_owned) |owned| host.discard(host.context, owned);

                const opened = try self.group.model.openEditor(
                    &copied_input.base,
                    options,
                );
                if (!opened.is_new) {
                    // The target already shows this document; upstream's
                    // `copyEditor` reveals that pane instead of adding a duplicate.
                    const existing = self.tabForInput(opened.editor) orelse return error.EditorAlreadyOpen;
                    copied_input.deinit();
                    input_owned = false;
                    return existing;
                }
                errdefer _ = self.group.model.closeEditor(&copied_input.base, .UNKNOWN, true) catch {};

                const copied = try TabType.initFromInput(host.view_factory, self.allocator, copied_input);
                tab_owned = copied;
                input_owned = false;
                try self.finishCopiedEditor(copied, host);
                return copied;
            }

            if (tab.image_input) |image_input| {
                const copied_input = try ImagePreviewEditorInput.init(self.allocator, image_input.path);
                var input_owned = true;
                errdefer if (input_owned) copied_input.deinit();
                var tab_owned: ?View = null;
                errdefer if (tab_owned) |owned| host.discard(host.context, owned);

                const opened = try self.group.model.openEditor(
                    &copied_input.base,
                    options,
                );
                if (!opened.is_new) {
                    const existing = self.tabForInput(opened.editor) orelse return error.EditorAlreadyOpen;
                    copied_input.deinit();
                    input_owned = false;
                    return existing;
                }
                errdefer _ = self.group.model.closeEditor(&copied_input.base, .UNKNOWN, true) catch {};

                const dims = self.contentDimensions();
                const copied = try TabType.initImageFromInput(
                    host.view_factory,
                    self.allocator,
                    host.io,
                    copied_input,
                    dims.width,
                    dims.height,
                    host.images,
                    host.window,
                );
                tab_owned = copied;
                input_owned = false;
                try self.finishCopiedEditor(copied, host);
                return copied;
            }

            // Diff/snapshot tabs own their models and inputs. Upstream copies the
            // side-by-side input; the terminal diff view is not model/view split
            // yet, so there is nothing safe to duplicate. Leave the layout
            // unchanged rather than opening an empty group.
            return error.SplitUnsupported;
        }

        pub fn finishCopiedEditor(self: *Self, tab: View, host: CopyEditorHost) !void {
            tab.setAsyncIo(host.async_io);
            tab.setImageRuntime(host.images);
            try tab.view.setStatusBarVisible(false);
            try self.addTab(tab);
            errdefer _ = self.removeTab(tab);
            host.configure(host.context, tab);
            try tab.ensureControllers();
            try self.activateTab(tab);
            try tab.refresh();
        }

        pub const MoveEditorHost = struct {
            context: *anyopaque,
            will_move: *const fn (*anyopaque, *Self, View) void,
            discard: *const fn (*anyopaque, View) void,
            focus_editor: *const fn (*anyopaque) void,
        };

        /// Upstream moveEditor/doMoveOrCopyEditorAcrossGroups: open in the
        /// target before closing the source. The terminal host only handles
        /// drag cancellation, the losing pane's external registrations and
        /// terminal focus after a transfer.
        pub fn moveEditor(self: *Self, dest: *Self, tab: View, options: @import("../../../common/editor/editorGroupModel.zig").EditorOpenOptions, host: MoveEditorHost) !View {
            if (self == dest) {
                if (options.index) |index| {
                    if (try self.group.model.moveEditor(tab.input, index) != null) _ = try self.group.model.pin(tab.input);
                }
                if (options.sticky) _ = try self.group.model.stick(tab.input);
                return tab;
            }
            try dest.tabs.ensureUnusedCapacity(1);
            try tab.ensureControllers();
            host.will_move(host.context, self, tab);
            // Open first, like upstream `doMoveOrCopyEditorAcrossGroups`: when the
            // target already shows a matching input (split copies have distinct
            // inputs over one model) the model reuses that editor and the moved
            // view is disposed instead of adding a second tab for the same model.
            const opened = try dest.group.model.openEditor(
                tab.input,
                options,
            );

            if (!opened.is_new) {
                const existing = dest.tabForInput(opened.editor);
                // Split copies share one document, so discarding the moved view is
                // safe. A session-restored duplicate can own a different document;
                // never discard unsaved edits from it.
                if (existing) |target_tab| {
                    if (target_tab.editor.model != tab.editor.model and tab.editor.isDirty()) {
                        try dest.activateTab(target_tab);
                        tab.editor.setMessage(
                            "Move blocked: {s} is already open with unsaved changes in the target group",
                            .{tab.input.getName()},
                        );
                        if (!options.preserve_focus) {
                            self.group.service.activateGroup(dest.group);
                            host.focus_editor(host.context);
                        }
                        return target_tab;
                    }
                }
            }

            _ = try self.group.model.closeEditor(tab.input, .MOVE, false);
            _ = self.removeTab(tab);
            self.syncActivePane();
            // Moving the last active tab leaves the model without an active editor
            // even when the group still has tabs; activate one so the group keeps
            // its breadcrumb/editor chrome.
            if (self.activeTab() == null and self.tabs.items.len > 0) {
                try self.activateTab(self.tabs.items[0]);
            }

            if (!opened.is_new) {
                const existing = dest.tabForInput(opened.editor) orelse return error.EditorAlreadyOpen;
                try dest.activateTab(existing);
                if (!options.preserve_focus) existing.focusEditor();
                // The moved view loses to the already-open tab; detach every
                // workbench registration before destroying it.
                host.discard(host.context, tab);
                if (!options.preserve_focus) {
                    self.group.service.activateGroup(dest.group);
                    host.focus_editor(host.context);
                }
                return existing;
            }

            try dest.addTab(tab);
            if (!options.preserve_focus) {
                self.group.service.activateGroup(dest.group);
                tab.focusEditor();
                host.focus_editor(host.context);
            }
            return tab;
        }

        /// Terminal window hooks for the remaining pane disposal and focus
        /// boundary. Confirmation, reveal, save and revert belong to the group.
        pub const CloseHost = struct {
            context: *anyopaque,
            prepare_dialog: *const fn (*anyopaque) void,
            focus_editor: *const fn (*anyopaque, ?View) void,
            is_alive: *const fn (*anyopaque, *Self, View) bool,
            close_tab: *const fn (*anyopaque, *Self, View) anyerror!void,
            report_error: *const fn (*anyopaque, anyerror) void,
        };

        fn shouldConfirmClose(input: *const EditorInput) bool {
            if (input.close_handler) |handler| return handler.show_confirm(handler.context);
            return input.isDirty() and !input.isSaving();
        }

        fn isOpenedInOtherGroup(self: *Self, input: *EditorInput) bool {
            for (self.group.service.groups.items) |group| {
                if (group == self.group) continue;
                if (group.model.contains(.{ .input = input }, .{})) return true;
            }
            return false;
        }

        /// Upstream handleCloseConfirmation, with the asynchronous result
        /// delivered by the file dialog service on the window thread.
        pub fn handleCloseConfirmation(self: *Self, tab: View, dialog_service: dialogs.IDialogService, host: CloseHost) !void {
            const input = tab.editorInput();
            if (!shouldConfirmClose(input) or self.isOpenedInOtherGroup(input)) {
                try host.close_tab(host.context, self, tab);
                return;
            }
            host.prepare_dialog(host.context);
            self.group.service.activateGroup(self.group);
            try self.activateTab(tab);
            try tab.ensureControllers();
            host.focus_editor(host.context, tab);

            const pending = try self.allocator.create(CloseConfirmation);
            errdefer self.allocator.destroy(pending);
            pending.* = .{ .allocator = self.allocator, .pane = self, .tab = tab, .host = host };
            _ = try file_dialogs.showSaveConfirm(self.allocator, dialog_service, &.{input.getName()}, .{
                .context = pending,
                .complete = CloseConfirmation.complete,
                .dispose = CloseConfirmation.dispose,
            });
        }

        /// Upstream closeEditors: confirm the entire set before closing any
        /// editor, then close inactive editors before the active editor.
        pub const CloseEditorsOptions = struct {
            preserve_focus: bool = false,
            completion: ?struct { context: *anyopaque, complete: *const fn (*anyopaque, bool) void } = null,
        };

        pub fn closeEditors(self: *Self, tabs_to_close: []const View, dialog_service: dialogs.IDialogService, host: CloseHost) !void {
            try self.closeEditorsWithOptions(tabs_to_close, dialog_service, host, .{});
        }

        /// Completion is called exactly once after a started operation, also
        /// when a confirmation is canceled or disposed. Allocation errors
        /// before starting the operation are returned to the caller.
        pub fn closeEditorsWithOptions(self: *Self, tabs_to_close: []const View, dialog_service: dialogs.IDialogService, host: CloseHost, options: CloseEditorsOptions) !void {
            if (tabs_to_close.len == 0 or dialog_service.hasDialog()) {
                if (options.completion) |completion| completion.complete(completion.context, tabs_to_close.len == 0);
                return;
            }
            for (tabs_to_close) |tab| if (tab.editorInput().hasCapability(@import("../../../common/editor.zig").EditorInputCapabilities.CannotClose)) {
                if (options.completion) |completion| completion.complete(completion.context, false);
                return;
            };
            const tabs = try self.allocator.dupe(View, tabs_to_close);
            const state = self.allocator.create(CloseEditorsOperation) catch |err| {
                self.allocator.free(tabs);
                return err;
            };
            state.* = .{ .allocator = self.allocator, .pane = self, .tabs = tabs, .dialog_service = dialog_service, .host = host, .options = options };
            defer state.release();
            state.confirmNext() catch |err| {
                host.report_error(host.context, err);
                state.finish(false);
            };
        }

        const CloseEditorsOperation = struct {
            allocator: Allocator,
            pane: *Self,
            tabs: []View,
            dialog_service: dialogs.IDialogService,
            host: CloseHost,
            options: CloseEditorsOptions,
            next: usize = 0,
            refs: usize = 1,

            fn finish(self: *CloseEditorsOperation, success: bool) void {
                const completion = self.options.completion orelse return;
                self.options.completion = null;
                completion.complete(completion.context, success);
            }

            fn release(self: *CloseEditorsOperation) void {
                self.refs -= 1;
                if (self.refs != 0) return;
                self.finish(false);
                self.allocator.free(self.tabs);
                self.allocator.destroy(self);
            }

            fn confirmNext(self: *CloseEditorsOperation) !void {
                const host = self.host;
                while (self.next < self.tabs.len) {
                    const tab = self.tabs[self.next];
                    self.next += 1;
                    if (!host.is_alive(host.context, self.pane, tab)) continue;
                    const input = tab.editorInput();
                    if (!shouldConfirmClose(input) or self.pane.isOpenedInOtherGroup(input)) continue;
                    host.prepare_dialog(host.context);
                    self.pane.group.service.activateGroup(self.pane.group);
                    try self.pane.activateTab(tab);
                    try tab.ensureControllers();
                    host.focus_editor(host.context, tab);
                    self.refs += 1;
                    errdefer self.release();
                    _ = try file_dialogs.showSaveConfirm(self.allocator, self.dialog_service, &.{input.getName()}, .{
                        .context = self,
                        .complete = complete,
                        .dispose = dispose,
                    });
                    return;
                }
                try self.doCloseEditors();
                self.finish(true);
            }

            fn complete(ptr: *anyopaque, result: dialogs.ConfirmResult) void {
                const self: *CloseEditorsOperation = @ptrCast(@alignCast(ptr));
                const host = self.host;
                const tab = self.tabs[self.next - 1];
                if (host.is_alive(host.context, self.pane, tab)) {
                    if (self.pane.doHandleCloseConfirmation(tab, result)) {
                        host.focus_editor(host.context, tab);
                        self.finish(false);
                        return;
                    }
                } else if (result == .CANCEL) {
                    self.finish(false);
                    return;
                }
                self.confirmNext() catch |err| {
                    host.report_error(host.context, err);
                    self.finish(false);
                };
            }

            fn dispose(ptr: *anyopaque) void {
                const self: *CloseEditorsOperation = @ptrCast(@alignCast(ptr));
                self.release();
            }

            fn doCloseEditors(self: *CloseEditorsOperation) !void {
                const host = self.host;
                var active: ?View = null;
                for (self.tabs) |tab| {
                    if (!host.is_alive(host.context, self.pane, tab)) continue;
                    if (self.pane.activeTab() == tab) {
                        active = tab;
                        continue;
                    }
                    try host.close_tab(host.context, self.pane, tab);
                }
                if (active) |tab| if (host.is_alive(host.context, self.pane, tab)) try host.close_tab(host.context, self.pane, tab);
                if (!self.options.preserve_focus) host.focus_editor(host.context, null);
            }
        };

        const CloseConfirmation = struct {
            allocator: Allocator,
            pane: *Self,
            tab: View,
            host: CloseHost,

            fn complete(context: *anyopaque, result: dialogs.ConfirmResult) void {
                const self: *CloseConfirmation = @ptrCast(@alignCast(context));
                const host = self.host;
                if (!host.is_alive(host.context, self.pane, self.tab)) {
                    host.focus_editor(host.context, null);
                    return;
                }
                if (self.pane.doHandleCloseConfirmation(self.tab, result)) {
                    host.focus_editor(host.context, self.tab);
                    return;
                }
                host.close_tab(host.context, self.pane, self.tab) catch |err| {
                    host.report_error(host.context, err);
                    return;
                };
                host.focus_editor(host.context, null);
            }

            fn dispose(context: *anyopaque) void {
                const self: *CloseConfirmation = @ptrCast(@alignCast(context));
                self.allocator.destroy(self);
            }
        };

        /// Return true if the close is vetoed. The terminal's file inputs save
        /// synchronously. Autosave-on-focus/window change and custom async
        /// confirm are still unported; the result is rechecked after the dialog.
        fn doHandleCloseConfirmation(self: *Self, tab: View, result: dialogs.ConfirmResult) bool {
            if (result == .CANCEL) return true;
            const input = tab.editorInput();
            if (input.close_handler == null and !shouldConfirmClose(input)) return false;
            switch (result) {
                .SAVE => {
                    _ = input.save(self.group.id) catch |err| {
                        tab.editor.setMessage("Unable to save {s}: {s}", .{ input.getName(), @errorName(err) });
                        return true;
                    };
                    return input.isDirty();
                },
                .DONT_SAVE => {
                    // Fall back to closing the final view when disk revert
                    // fails, as in the existing terminal soft-revert boundary.
                    input.revert(self.group.id) catch return false;
                    return input.isDirty();
                },
                .CANCEL => unreachable,
            }
        }

        pub fn addTab(self: *Self, tab: View) !void {
            try self.tabs.append(tab);
            if (@hasDecl(@typeInfo(View).pointer.child, "setControlChangeService")) tab.setControlChangeService(self.group.service);
            if (@hasDecl(@typeInfo(View).pointer.child, "attachWindow")) if (self.window) |window| tab.attachWindow(window);
            if (self.group.model.isActive(.{ .input = tab.editorInput() })) {
                self.setActivePane(tab);
            }
        }

        /// Unregisters and returns the view for `tab`; the caller owns it.
        pub fn removeTab(self: *Self, tab: View) ?View {
            const index = self.indexOfTab(tab) orelse return null;
            if (self.panes.activePane() == tab) self.setActivePane(null);
            if (@hasDecl(@typeInfo(View).pointer.child, "setControlChangeService")) tab.setControlChangeService(null);
            return self.tabs.orderedRemove(index);
        }

        /// Upstream `setActive` plus switching the visible editor pane.
        pub fn activateTab(self: *Self, tab: View) !void {
            _ = try self.group.model.setActive(tab.editorInput());
            self.setActivePane(tab);
        }

        /// Mirrors the model change after a close/move: the active pane follows
        /// the model's new active editor, or is cleared when the group empties.
        pub fn syncActivePane(self: *Self) void {
            self.setActivePane(self.activeTab());
        }

        pub fn closeEditor(self: *Self, input: *EditorInput) void {
            const pane = self.panes.activePane() orelse return;
            if (pane.editorInput() == input) self.setActivePane(null);
        }

        fn setActivePane(self: *Self, pane: ?View) void {
            const previous = self.panes.activePane();
            self.panes.setActive(pane);
            if (pane != previous) {
                if (comptime @hasField(@typeInfo(View).pointer.child, "diff")) {
                    if (pane) |tab| {
                        if (comptime @hasField(@typeInfo(View).pointer.child, "multi_diff")) {
                            if (tab.multi_diff) |multi| {
                                self.title_control.setActiveMultiDiff(multi) catch {};
                            } else self.title_control.setActiveDiff(if (tab.diff) |diff| diff.widget else null) catch {};
                        } else self.title_control.setActiveDiff(if (tab.diff) |diff| diff.widget else null) catch {};
                    } else self.title_control.setActiveDiff(null) catch {};
                }
                if (self.updateBreadcrumbsVisibility() and self.panes.page_position != null) self.layout();
            }
            if (pane != previous) {
                self.on_did_change_active_editor_pane.fire(pane) catch {};
                self.group.service.on_did_visible_editors_change.fire({}) catch {};
            }
        }

        pub fn interface(self: *Self) editor_groups.IEditorGroup {
            return .{
                .context = self,
                .id = self.group.id,
                .focus_fn = struct {
                    fn focus(context: *anyopaque) void {
                        const view: *Self = @ptrCast(@alignCast(context));
                        view.focus();
                    }
                }.focus,
                .count_fn = struct {
                    fn count(context: *anyopaque) usize {
                        const view: *Self = @ptrCast(@alignCast(context));
                        return view.group.model.count();
                    }
                }.count,
                .active_index_fn = struct {
                    fn activeIndex(context: *anyopaque) ?usize {
                        const view: *Self = @ptrCast(@alignCast(context));
                        return view.group.model.indexOf(.{ .input = view.group.model.activeEditor() orelse return null });
                    }
                }.activeIndex,
                .get_editor_by_index = struct {
                    fn get(context: *anyopaque, index: usize) ?*EditorInput {
                        const view: *Self = @ptrCast(@alignCast(context));
                        return view.group.model.getEditorByIndex(index);
                    }
                }.get,
                .open_editor = struct {
                    fn open(context: *anyopaque, input: *EditorInput) !void {
                        const view: *Self = @ptrCast(@alignCast(context));
                        const tab = view.tabForInput(input) orelse return;
                        try view.activateTab(tab);
                        if (@hasDecl(@typeInfo(View).pointer.child, "ensureControllers")) try tab.ensureControllers();
                        view.focus();
                        if (@hasDecl(@typeInfo(View).pointer.child, "refresh")) try tab.refresh();
                    }
                }.open,
            };
        }

        /// Upstream `EditorGroupView.focus()`: pass focus to the active editor
        /// pane, then fire `onDidFocus`. An empty group focuses its container
        /// upstream; the terminal group has no focusable container, so only the
        /// event remains.
        pub fn focus(self: *Self) void {
            if (self.activeTab()) |tab| tab.focusEditor();
            self.on_did_focus.fire(self) catch {};
        }

        /// Upstream `layout(pagePosition)`: assign the group rectangle and lay
        /// out the title control, the breadcrumb bar and the visible editor
        /// pane. Panes activated later re-use this position.
        pub fn updatePartOptions(self: *Self, show_tabs: @import("../../../services/layout/browser/layoutService.zig").EditorTabsMode, breadcrumbs_enabled: bool) void {
            self.setTabsVisible(switch (show_tabs) {
                .none => false,
                .single => self.tabs.items.len > 1,
                .multiple => true,
            });
            self.setBreadcrumbsVisible(breadcrumbs_enabled);
            _ = self.updateBreadcrumbsVisibility();
        }

        fn updateBreadcrumbsVisibility(self: *Self) bool {
            const previous = self.breadcrumbs_suppressed;
            if (@hasField(@typeInfo(View).pointer.child, "terminal_input")) {
                self.breadcrumbs_suppressed = if (self.activeTab()) |tab| tab.terminal_input != null or tab.search_editor_input != null or tab.markdown_panel != null else false;
            }
            return previous != self.breadcrumbs_suppressed;
        }

        pub fn layout(self: *Self) void {
            const width = @max(ui.cell.snap(self.rect.w), 1);
            const height = @max(ui.cell.snap(self.rect.h) -| self.chromeHeight(), 1);
            self.panes.layout(.{ .width = width, .height = height });
        }

        /// Rows owned by the title control above the editor content.
        pub fn titleHeight(self: *const Self) usize {
            return if (self.tabs_visible) title_height else 0;
        }

        pub fn contentDimensions(self: *const Self) struct { width: usize, height: usize } {
            return .{ .width = @max(ui.cell.snap(self.rect.w), 1), .height = @max(ui.cell.snap(self.rect.h) -| self.chromeHeight(), 1) };
        }
        pub fn chromeHeight(self: *const Self) usize {
            return self.titleHeight() + if (self.breadcrumbsVisible()) breadcrumbs_height else 0;
        }

        pub fn breadcrumbsVisible(self: *const Self) bool {
            return self.breadcrumbs_visible and !self.breadcrumbs_suppressed;
        }

        pub fn setTabsVisible(self: *Self, visible: bool) void {
            self.tabs_visible = visible;
        }

        pub fn setBreadcrumbsVisible(self: *Self, visible: bool) void {
            self.breadcrumbs_visible = visible;
        }
    };
}

const GroupDom = struct {
    split_view: *ui.Node,
    group: *ui.Node,
    title: *ui.Node,
    editor_container: *ui.Node,

    fn create(grid: *ui.Node) !GroupDom {
        const doc = grid.document;
        const split_view = try doc.createElement(.div);
        errdefer doc.destroy(split_view);
        try split_view.addClass(css.splitview.Class.split_view_view);
        _ = try grid.appendChild(split_view);
        const group = try doc.createElement(.div);
        _ = try split_view.appendChild(group);
        try group.addClass(css.editor_group.Class.editor_group_container);
        group.setStyle(.{ .position = .relative });
        const title = try doc.createElement(.div);
        _ = try group.appendChild(title);
        try title.addClass(css.editor_group.Class.title);
        const editor_container = try doc.createElement(.div);
        _ = try group.appendChild(editor_container);
        return .{ .split_view = split_view, .group = group, .title = title, .editor_container = editor_container };
    }
};

fn setStyleIfChanged(node: *ui.Node, style: ui.Style) void {
    if (!std.meta.eql(node.asElement().style, style)) node.setStyle(style);
}

const TestInput = struct {
    base: EditorInput,
    id: []const u8,

    fn create(allocator: Allocator, id: []const u8) !*TestInput {
        const input = try allocator.create(TestInput);
        input.* = .{
            .base = EditorInput.init(allocator, "test.editorInput"),
            .id = id,
        };
        input.base.impl = input;
        input.base.matches_fn = matches;
        return input;
    }

    fn deinit(self: *TestInput) void {
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        const self: *TestInput = @ptrCast(@alignCast(base.impl.?));
        const other_input: *TestInput = @ptrCast(@alignCast(other.impl.?));
        return std.mem.eql(u8, "test.editorInput", other.type_id) and
            std.mem.eql(u8, self.id, other_input.id);
    }
};

const TestTab = struct {
    input: *TestInput,
    layouts: usize = 0,
    focuses: usize = 0,
    width: usize = 0,
    height: usize = 0,

    pub fn editorInput(self: *TestTab) *EditorInput {
        return &self.input.base;
    }

    pub fn layoutCells(self: *TestTab, width: usize, height: usize) void {
        self.layouts += 1;
        self.width = width;
        self.height = height;
    }

    pub fn focusEditor(self: *TestTab) void {
        self.focuses += 1;
    }

    pub fn deinit(self: *TestTab) void {
        _ = self;
    }
};

fn testGroup(allocator: Allocator) !*editor_groups.EditorGroupsService {
    return editor_groups.EditorGroupsService.init(allocator, .{});
}

test "EditorGroupView: registers tabs in model order and tracks the active tab" {
    const allocator = std.testing.allocator;
    const service = try testGroup(allocator);
    const group = service.activeGroup();

    const first = try TestInput.create(allocator, "first");
    defer first.deinit();
    const second = try TestInput.create(allocator, "second");
    defer second.deinit();
    // The model unlistens from its inputs, so dispose it before the inputs.
    defer service.deinit();

    var first_tab = TestTab{ .input = first };
    var second_tab = TestTab{ .input = second };
    const View = EditorGroupView(*TestTab);
    var view = View.init(allocator, group);
    defer view.deinit();

    _ = try group.model.openEditor(&first.base, .{ .pinned = true, .active = true });
    try view.addTab(&first_tab);
    _ = try group.model.openEditor(&second.base, .{ .pinned = true, .active = false });
    try view.addTab(&second_tab);

    try std.testing.expectEqual(@as(usize, 2), view.count());
    try std.testing.expectEqual(&first_tab, view.activeTab().?);

    var ordered = std.array_list.Managed(*TestTab).init(allocator);
    defer ordered.deinit();
    try view.orderedTabs(allocator, &ordered);
    try std.testing.expectEqual(@as(usize, 2), ordered.items.len);
    try std.testing.expectEqual(&first_tab, ordered.items[0]);
    try std.testing.expectEqual(&second_tab, ordered.items[1]);
    try std.testing.expectEqual(@as(usize, 0), view.activeIndex(ordered.items));
    try std.testing.expectEqual(&second_tab, view.tabAtIndex(allocator, 1).?);
}

test "EditorGroupView: activation switches the visible pane and lays it out" {
    const allocator = std.testing.allocator;
    const service = try testGroup(allocator);
    const group = service.activeGroup();

    const input = try TestInput.create(allocator, "only");
    defer input.deinit();
    // The model unlistens from its inputs, so dispose it before the input.
    defer service.deinit();
    var tab = TestTab{ .input = input };
    const View = EditorGroupView(*TestTab);
    var view = View.init(allocator, group);
    defer view.deinit();

    _ = try group.model.openEditor(&input.base, .{ .pinned = true, .active = true });
    view.rect = .{ .x = 0, .y = 0, .w = 40, .h = 10 };
    view.layout();
    try view.addTab(&tab);

    // addTab lays out the pane once for the new active editor at the recorded
    // page position.
    try std.testing.expectEqual(@as(usize, 1), tab.layouts);
    try std.testing.expectEqual(@as(usize, 40), tab.width);
    try std.testing.expectEqual(@as(usize, 9), tab.height);

    view.layout();
    try std.testing.expectEqual(@as(usize, 2), tab.layouts);

    _ = try view.activateTab(&tab);
    try std.testing.expectEqual(@as(usize, 3), tab.layouts);
    try std.testing.expectEqual(&tab, view.panes.activePane().?);
}

test "EditorGroupView: removing the active tab clears the pane and sync follows the model" {
    const allocator = std.testing.allocator;
    const service = try testGroup(allocator);
    const group = service.activeGroup();

    const first = try TestInput.create(allocator, "first");
    defer first.deinit();
    const second = try TestInput.create(allocator, "second");
    defer second.deinit();
    // The model unlistens from its inputs, so dispose it before the inputs.
    defer service.deinit();
    var first_tab = TestTab{ .input = first };
    var second_tab = TestTab{ .input = second };

    const View = EditorGroupView(*TestTab);
    var view = View.init(allocator, group);
    defer view.deinit();

    _ = try group.model.openEditor(&first.base, .{ .pinned = true, .active = true });
    try view.addTab(&first_tab);
    _ = try group.model.openEditor(&second.base, .{ .pinned = true, .active = false });
    try view.addTab(&second_tab);
    try view.activateTab(&second_tab);
    try std.testing.expectEqual(&second_tab, view.panes.activePane().?);

    _ = try group.model.closeEditor(&second.base, .UNKNOWN, true);
    try std.testing.expectEqual(&second_tab, view.removeTab(&second_tab).?);
    try std.testing.expect(view.panes.activePane() == null);

    view.syncActivePane();
    try std.testing.expectEqual(&first_tab, view.panes.activePane().?);
}

test "EditorGroupView: focus forwards to the active pane and fires onDidFocus" {
    const allocator = std.testing.allocator;
    const service = try testGroup(allocator);
    const group = service.activeGroup();

    const input = try TestInput.create(allocator, "focus");
    defer input.deinit();
    // The model unlistens from its inputs, so dispose it before the input.
    defer service.deinit();
    var tab = TestTab{ .input = input };
    const View = EditorGroupView(*TestTab);
    var view = View.init(allocator, group);
    defer view.deinit();

    _ = try group.model.openEditor(&input.base, .{ .pinned = true, .active = true });
    try view.addTab(&tab);

    var focused: usize = 0;
    _ = try view.on_did_focus.listen(&focused, struct {
        fn cb(_: *View, count: *usize) anyerror!void {
            count.* += 1;
        }
    }.cb);

    view.focus();
    try std.testing.expectEqual(@as(usize, 1), tab.focuses);
    try std.testing.expectEqual(@as(usize, 1), focused);

    // An empty group still fires the focus event; only the pane focus is skipped.
    const other = try testGroup(allocator);
    defer other.deinit();
    var empty = View.init(allocator, other.activeGroup());
    defer empty.deinit();
    var empty_focused: usize = 0;
    _ = try empty.on_did_focus.listen(&empty_focused, struct {
        fn cb(_: *View, count: *usize) anyerror!void {
            count.* += 1;
        }
    }.cb);
    empty.focus();
    try std.testing.expectEqual(@as(usize, 1), empty_focused);
}
