// Port of `src/vs/editor/browser/widget/multiDiffEditor/diffEditorItemTemplate.ts`.
// A pooled header DOM surface and clipped body frame replace absolutely
// positioned browser elements. Code-editor views remain real editor views
// over the item-owned models; the current native code editor construction
// API requires creating those views on binding and disposing them on unbind.
const std = @import("std");
const ui = @import("ui");
const Allocator = std.mem.Allocator;
const model = @import("multiDiffEditorViewModel.zig");
const variants = @import("multiDiffEditorOptions.zig");
const vm = @import("virtualizedItemManager.zig");
const css = @import("style_css.zig");
const editor_css = @import("../../editorCss.zig");
const DiffWidget = @import("../diffEditor/diffEditorWidget.zig").DiffEditorWidget;
const DiffOptions = @import("../diffEditor/diffEditorOptions.zig").Options;
const Editor = @import("../codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const model_types = @import("../../../common/model.zig");
const Range = @import("../../../common/core/range.zig").Range;
const time = @import("../../../../base/common/timeCompat.zig");
const OffsetRange = @import("../../../common/core/ranges/offsetRange.zig").OffsetRange;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const ContentSizeChangedEvent = @import("../../../common/viewModelEventDispatcher.zig").ContentSizeChangedEvent;
const ThemeColors = @import("../../../../workbench/browser/themeColors.zig").ThemeColors;
const std_uri = @import("../../../../base/common/stdUri.zig");

const symbol_highlight_options = blk: {
    var options = model_types.ModelDecorationOptions.init("symbol-navigate-action-highlight", .NeverGrowsWhenTypingAtEdges);
    options.className = "symbolHighlight";
    options.inlineClassName = "symbolHighlight";
    break :blk options;
};

pub const binaryFilePlaceholderContentHeight: usize = 5;
pub const ItemAction = enum { collapse, open_file, open_binary_diff };
pub const ViewMode = enum { inline_view, side_by_side, automatic };

pub const Configuration = struct {
    variant: variants.IMultiDiffEditorVariantConfiguration,
    width: usize = 1,
    render_side_by_side: ?bool = null,
    use_inline_when_limited: ?bool = null,
    word_wrap: ?@import("../diffEditor/diffEditorOptions.zig").DiffWordWrap = null,
    hide_original_line_numbers: ?bool = null,
    theme: ?*const ThemeColors = null,

    pub fn outerHeight(self: *const Configuration) usize {
        return self.variant.headerHeight + self.variant.contentBottomPadding;
    }
    pub fn unboundSize(self: *const Configuration, item: *model.DocumentDiffItemViewModel) usize {
        if (item.collapsed) return self.variant.headerHeight;
        if (item.isBinary()) return self.outerHeight() + binaryFilePlaceholderContentHeight;
        return @max(self.outerHeight() + 1, item.lastTemplateData.expandedContentHeight);
    }
    pub fn editorOptions(self: *const Configuration, item: *model.DocumentDiffItemViewModel) DiffOptions {
        var options = item.options;
        options.variant = if (self.variant.diffEditorVariant != null) .compact else .normal;
        options.hide_original_line_numbers = self.hide_original_line_numbers orelse item.documentDiffItem.hideOriginalLineNumbers orelse self.variant.hideOriginalLineNumbers;
        options.render_overview_ruler = false;
        options.hide_unchanged_regions = true;
        if (self.render_side_by_side) |value| options.render_side_by_side = value;
        if (self.use_inline_when_limited) |value| options.use_inline_view_when_space_is_limited = value;
        if (self.word_wrap) |value| options.diff_word_wrap = value;
        return options;
    }
};

pub fn DiffEditorItemTemplate(comptime View: type) type {
    return struct {
        const Self = @This();
        pub const Widget = DiffWidget(View);
        pub const Host = struct {
            context: *anyopaque,
            view_factory: *const fn (Allocator, *Editor) anyerror!*View,
            configure_diff: ?*const fn (*anyopaque, *Widget) anyerror!void = null,
            dispose_diff: ?*const fn (*anyopaque, *Widget) void = null,
            open_file: ?*const fn (*anyopaque, std.Uri) anyerror!void = null,
            open_binary_diff: ?*const fn (*anyopaque, std.Uri, std.Uri) anyerror!void = null,
        };
        allocator: Allocator,
        io: std.Io,
        config: *Configuration,
        host: Host,
        queue: *dispatch.Queue,
        virtualized_template: vm.VirtualizedItemTemplate(model.DocumentDiffItemViewModel, Binding),
        header: ui.Surface,
        root: *ui.Node = undefined,
        row: *ui.Node = undefined,
        collapse_button: *ui.Node = undefined,
        primary_path: *ui.Node = undefined,
        secondary_path: *ui.Node = undefined,
        status: *ui.Node = undefined,
        actions: *ui.Node = undefined,
        pending_action: ?ItemAction = null,
        body_frame: ?ui.Frame = null,

        pub const Binding = struct {
            item: *model.DocumentDiffItemViewModel,
            template: *Self,
            context: vm.IVirtualizedItemBindingContext,
            editor: ?*Widget = null,
            measured_height: usize,
            observed_height: usize,
            measured_max_scroll: usize = 0,
            width: usize = 0,
            rendered_range: OffsetRange = .init(0, 0),
            rendered_viewport: OffsetRange = .init(0, 0),
            scroll_offset: usize = 0,
            hidden: bool = false,
            setting_data: bool = false,
            vertical_update: dispatch.Task = .{},
            highlight_timeout: dispatch.Task = .{},
            highlighted_model: ?*TextModel = null,
            options_listener: ?usize = null,
            original_size_listener: ?usize = null,
            modified_size_listener: ?usize = null,

            pub fn size(self: *Binding) usize {
                return if (self.item.collapsed) self.template.config.variant.headerHeight else self.getExpandedContentHeight();
            }
            pub fn maxScroll(self: *Binding) usize {
                return self.measured_max_scroll;
            }
            pub fn getExpandedContentHeight(self: *Binding) usize {
                return self.measured_height + self.template.config.outerHeight();
            }
            pub fn shouldKeepAlive(self: *Binding) bool {
                return self.item.isFocused;
            }
            pub fn render(self: *Binding, range: OffsetRange, offset: usize, width: usize, viewport: OffsetRange) !void {
                self.hidden = false;
                self.rendered_range = range;
                self.rendered_viewport = viewport;
                self.scroll_offset = offset;
                self.width = width;
                const config = self.template.config;
                const body_width = @max(width -| config.variant.horizontalInsets.left -| config.variant.horizontalInsets.right, 1);
                const body_height = @max(range.length() -| config.outerHeight(), 1);
                try self.template.header.resize(@max(width, 1), config.variant.headerHeight);
                try self.template.updateHeader(self.item);
                try self.template.root.setClasses([_]css.Class{.header});
                if (offset > 0 or self.headerRange().start > range.start) try self.template.root.addClass(css.Class.shadow);
                if (self.item.collapsed) try self.template.root.addClass(css.Class.collapsed);
                if (self.editor) |editor| {
                    self.setting_data = true;
                    editor.layout(body_width, body_height);
                    _ = editor.original_editor.setScrollTop(offset);
                    _ = editor.modified_editor.setScrollTop(offset);
                    self.setting_data = false;
                    self.observeHeight();
                    self.flushHeight();
                }
            }
            fn observeHeight(self: *Binding) void {
                if (self.editor) |editor| {
                    const original = editor.original_editor.viewLayout();
                    const modified = editor.modified_editor.viewLayout();
                    if (self.item.diffEditorViewModel.is_diff_up_to_date) {
                        self.observed_height = @max(@as(usize, 1), @as(usize, @intFromFloat(@max(original.getContentHeight(), modified.getContentHeight()))));
                    }
                    const original_overflow: usize = @intFromFloat(@max(0, original.getContentWidth() - original.viewport_width));
                    const modified_overflow: usize = @intFromFloat(@max(0, modified.getContentWidth() - modified.viewport_width));
                    self.measured_max_scroll = @max(original_overflow, modified_overflow);
                }
            }
            fn onContentSizeChanged(_: ContentSizeChangedEvent, self: *Binding) !void {
                if (!self.setting_data) self.vertical_update.post();
            }
            fn onVerticalUpdate(context: *anyopaque, _: i64, _: bool) bool {
                const self: *Binding = @ptrCast(@alignCast(context));
                const old_height = self.measured_height;
                const old_max_scroll = self.measured_max_scroll;
                self.observeHeight();
                self.flushHeight();
                if (old_height != self.measured_height or old_max_scroll != self.measured_max_scroll) self.context.notifyChanged() catch {};
                // The callback may have caused unbinding; do not use self.
                return true;
            }
            fn flushHeight(self: *Binding) void {
                self.vertical_update.schedule(null);
                self.measured_height = self.observed_height;
            }
            fn onOptionsChanged(_: void, self: *Binding) !void {
                try self.updateOptions();
            }
            pub fn updateOptions(self: *Binding) !void {
                if (self.editor) |editor| {
                    _ = try editor.updateOptions(self.template.config.editorOptions(self.item));
                    editor.setThemeColors(self.template.config.theme);
                }
                self.vertical_update.post();
            }
            pub fn hide(self: *Binding) void {
                self.hidden = true;
            }
            /// Port of the transient symbol-highlight decoration used by
            /// multiDiffEditorWidgetImpl.reveal. The binding owns the model
            /// decoration and the 350 ms timeout, including unbind cleanup.
            pub fn highlightRange(self: *Binding, target: *Editor, range: Range) !void {
                self.clearHighlight();
                const text_model = target.model;
                const ids = try text_model.deltaDecorations(&.{}, &.{.{ .range = range, .options = @constCast(&symbol_highlight_options) }}, @intFromPtr(self));
                text_model.getAllocator().free(ids);
                self.highlighted_model = text_model;
                self.highlight_timeout.schedule(time.milliTimestamp() +| 350);
            }
            fn clearHighlight(self: *Binding) void {
                self.highlight_timeout.schedule(null);
                const text_model = self.highlighted_model orelse return;
                self.highlighted_model = null;
                text_model.removeAllDecorationsWithOwnerId(@intFromPtr(self)) catch {};
            }
            fn onHighlightTimeout(context: *anyopaque, _: i64, _: bool) bool {
                const self: *Binding = @ptrCast(@alignCast(context));
                self.clearHighlight();
                return true;
            }
            pub fn destroy(self: *Binding) void {
                self.vertical_update.schedule(null);
                self.clearHighlight();
                if (self.options_listener) |id| self.item.on_did_change_options.unlisten(id);
                if (self.editor) |editor| {
                    if (self.original_size_listener) |id| editor.original_editor.viewLayout().onDidContentSizeChange().unlisten(id);
                    if (self.modified_size_listener) |id| editor.modified_editor.viewLayout().onDidContentSizeChange().unlisten(id);
                    if (self.template.host.dispose_diff) |dispose| dispose(self.template.host.context, editor);
                    editor.destroy();
                }
                self.template.header.doc.blur();
                self.template.pending_action = null;
                self.template.allocator.destroy(self);
            }
            pub fn setScrollLeft(self: *Binding, left: usize) void {
                if (self.editor) |editor| {
                    const original = editor.original_editor.viewLayout();
                    const modified = editor.modified_editor.viewLayout();
                    if (modified.getContentWidth() - modified.viewport_width > original.getContentWidth() - original.viewport_width) {
                        _ = editor.modified_editor.setScrollLeft(left);
                    } else _ = editor.original_editor.setScrollLeft(left);
                }
            }
            pub fn headerRange(self: *const Binding) OffsetRange {
                const top = self.rendered_range.start + @min(self.rendered_viewport.start -| self.rendered_range.start, self.rendered_range.length() -| self.template.config.variant.headerHeight);
                return .init(top, @min(top + self.template.config.variant.headerHeight, self.rendered_range.endExclusive));
            }
            pub fn bodyRange(self: *const Binding) OffsetRange {
                const start = @min(self.rendered_range.start + self.template.config.variant.headerHeight, self.rendered_range.endExclusive);
                return .init(start, @max(start, self.rendered_range.endExclusive -| self.template.config.variant.contentBottomPadding));
            }
            pub fn paint(self: *Binding, frame: *ui.Frame, x: usize, y: usize) !void {
                if (self.hidden or self.width == 0) return;
                const template = self.template;
                if (!self.item.collapsed) {
                    const body = self.bodyRange();
                    const visible_start = @max(body.start, self.rendered_viewport.start);
                    const visible_end = @min(body.endExclusive, self.rendered_viewport.endExclusive);
                    if (visible_end > visible_start) {
                        const insets = template.config.variant.horizontalInsets;
                        const body_width = self.width -| insets.left -| insets.right;
                        if (body_width > 0) {
                            try template.ensureBodyFrame(body_width, body.length());
                            const target = &template.body_frame.?;
                            target.begin();
                            if (self.editor) |editor| {
                                try editor.paint(target, 0, 0, body_width, body.length());
                            } else {
                                const fg = ui.cell.packColor(template.color("descriptionForeground", .{ 150, 150, 150 }));
                                const bg = ui.cell.packColor(template.color("multiDiffEditor.background", .{ 30, 30, 30 }));
                                const paint_style: ui.cell.PaintStyle = .{ .fg = fg, .bg = bg };
                                target.next.fillRect(0, 0, @floatFromInt(body_width), @floatFromInt(body.length()), paint_style);
                                const label = "Binary file changed";
                                const clip: ui.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(body_width), .h = @floatFromInt(body.length()) };
                                ui.paint.drawText(&template.header.doc, &target.next, label, @floatFromInt((body_width -| label.len) / 2), @floatFromInt(body.length() / 2), paint_style, false, clip);
                                if (template.host.open_binary_diff != null and self.item.documentDiffItem.original != null and self.item.documentDiffItem.modified != null) {
                                    const action = "Open Diff";
                                    ui.paint.drawText(&template.header.doc, &target.next, action, @floatFromInt((body_width -| action.len) / 2), @floatFromInt(@min(body.length() - 1, body.length() / 2 + 1)), paint_style, false, clip);
                                }
                            }
                            try frame.next.blitRows(&target.next, x + insets.left, y + visible_start - self.rendered_viewport.start, visible_start - body.start, body_width, visible_end - visible_start);
                        }
                    }
                }
                // The file header is sticky and overlays the clipped body.
                const header = self.headerRange();
                const start = @max(header.start, self.rendered_viewport.start);
                const end = @min(header.endExclusive, self.rendered_viewport.endExclusive);
                if (end > start) {
                    try template.header.paintFrame();
                    try frame.next.blitRows(template.header.grid(), x, y + start - self.rendered_viewport.start, start - header.start, self.width, end - start);
                }
            }
            pub fn dispatchHeaderMouse(self: *Binding, event: *ui.MouseEvent, row: usize) !?ItemAction {
                const template = self.template;
                var local = event.*;
                local.y = row;
                if (try template.header.elementFromPoint(local.x, local.y)) |target| template.header.doc.dispatchMouse(target, &local);
                if (local.default_prevented) event.preventDefault();
                const action = template.pending_action;
                template.pending_action = null;
                return action;
            }
            pub fn pointerAt(self: *Binding, x: usize, absolute_row: usize) !ui.Pointer {
                const header = self.headerRange();
                if (header.contains(absolute_row)) return (try self.template.header.pointerAt(x, absolute_row - header.start)) orelse .default;
                const body = self.bodyRange();
                if (body.contains(absolute_row)) {
                    if (self.editor) |editor| return editor.pointerAt(x -| self.template.config.variant.horizontalInsets.left, absolute_row - body.start);
                }
                return .default;
            }
        };

        pub fn create(allocator: Allocator, io: std.Io, config: *Configuration, queue: *dispatch.Queue, host: Host) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .io = io,
                .config = config,
                .queue = queue,
                .host = host,
                .virtualized_template = .init(allocator),
                .header = try ui.Surface.init(allocator, .{ .cols = @max(config.width, 1), .rows = config.variant.headerHeight }),
            };
            errdefer self.header.deinit();
            errdefer self.virtualized_template.deinit();
            try self.buildHeader();
            return self;
        }
        pub fn destroy(self: *Self) void {
            self.virtualized_template.deinit();
            if (self.body_frame) |*frame| frame.deinit();
            self.header.deinit();
            self.allocator.destroy(self);
        }
        fn ensureBodyFrame(self: *Self, width: usize, height: usize) !void {
            if (self.body_frame) |*frame| if (frame.next.cols == width and frame.next.rows == height) return;
            const frame = try ui.Frame.init(self.allocator, width, height);
            if (self.body_frame) |*old| old.deinit();
            self.body_frame = frame;
        }
        fn color(self: *const Self, id: []const u8, fallback: [3]u8) ui.Color {
            return if (self.config.theme) |theme| theme.color(id, fallback) else .{ .r = fallback[0], .g = fallback[1], .b = fallback[2] };
        }
        fn element(parent: *ui.Node, class: css.Class, tag: ui.dom.Tag) !*ui.Node {
            const node = try parent.document.createElement(tag);
            errdefer parent.document.destroy(node);
            try node.addClass(class);
            _ = try parent.appendChild(node);
            return node;
        }
        fn buildHeader(self: *Self) !void {
            const doc = &self.header.doc;
            try editor_css.register(doc);
            self.root = try doc.createElement(.div);
            doc.setRoot(self.root);
            try self.root.addClass(css.Class.header);
            self.row = try element(self.root, .header_content, .div);
            self.collapse_button = try element(self.row, .collapse_button, .span);
            try self.collapse_button.setAttribute("role", "button");
            try self.collapse_button.setAttribute("aria-label", "Collapse or expand file");
            try self.collapse_button.addEventListener(.{ .context = self, .mouse_down = collapseClick });
            const file_path = try element(self.row, .file_path, .div);
            self.primary_path = try element(file_path, .title, .span);
            self.status = try element(file_path, .status, .span);
            self.secondary_path = try element(file_path, .title, .span);
            self.actions = try element(self.row, .actions, .span);
            try self.actions.setTextContent("↗");
            try self.actions.setAttribute("role", "button");
            try self.actions.setAttribute("aria-label", "Go to File");
            try self.actions.addEventListener(.{ .context = self, .mouse_down = openFileClick });
            try self.row.addEventListener(.{ .context = self, .mouse_down = headerClick });
        }
        pub fn updateHeader(self: *Self, item: *model.DocumentDiffItemViewModel) !void {
            const value = item.documentDiffItem;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const original = if (value.original) |source| try std_uri.path(source.uri, arena.allocator()) else "";
            const modified = if (value.modified) |source| try std_uri.path(source.uri, arena.allocator()) else "";
            const renamed = value.original != null and value.modified != null and !std.mem.eql(u8, original, modified);
            try self.collapse_button.setTextContent(if (item.collapsed) "›" else "⌄");
            try self.root.setAttribute("aria-expanded", if (item.collapsed) "false" else "true");
            try self.primary_path.setTextContent(if (value.modified != null) modified else original);
            try self.status.setTextContent(if (value.original == null) "A" else if (value.modified == null) "D" else if (renamed) "R" else "");
            try self.secondary_path.setTextContent(if (renamed) original else "");
            self.root.setStyle(.{ .background = self.color("multiDiffEditor.headerBackground", .{ 38, 38, 38 }), .color = self.color("foreground", .{ 204, 204, 204 }) });
            self.row.setStyle(.{ .bold = item.isActive(), .pointer = if (self.config.variant.headerClickToCollapse) .pointer else .default });
            self.primary_path.setStyle(.{ .strikethrough = value.modified == null });
            self.secondary_path.setStyle(.{ .strikethrough = true, .display = if (renamed) .inline_block else .none });
            self.status.setStyle(.{ .display = if (renamed or value.original == null or value.modified == null) .inline_block else .none });
            self.actions.setStyle(.{ .display = if (self.host.open_file != null) .flex else .none });
        }
        fn collapseClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            if (event.button == .left) {
                self.pending_action = .collapse;
                event.preventDefault();
                event.stopPropagation();
            }
        }
        fn openFileClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            if (event.button == .left) {
                self.pending_action = .open_file;
                event.preventDefault();
                event.stopPropagation();
            }
        }
        fn headerClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            if (event.button == .left and self.config.variant.headerClickToCollapse) {
                self.pending_action = .collapse;
                event.preventDefault();
            }
        }
        pub fn createBinding(self: *Self, item: *model.DocumentDiffItemViewModel, context: vm.IVirtualizedItemBindingContext) !*Binding {
            const height = if (item.isBinary()) binaryFilePlaceholderContentHeight else @max(1, @max(context.initialSize, item.lastTemplateData.expandedContentHeight) -| self.config.outerHeight());
            const binding = try self.allocator.create(Binding);
            binding.* = .{
                .item = item,
                .template = self,
                .context = context,
                .measured_height = height,
                .observed_height = height,
                .vertical_update = .{ .queue = self.queue, .context = binding, .run = Binding.onVerticalUpdate },
                .highlight_timeout = .{ .queue = self.queue, .context = binding, .run = Binding.onHighlightTimeout },
            };
            errdefer binding.destroy();
            if (!item.isBinary()) {
                const width = @max(self.config.width -| self.config.variant.horizontalInsets.left -| self.config.variant.horizontalInsets.right, 1);
                binding.editor = try Widget.createWithModelSources(self.host.view_factory, self.allocator, self.io, item.original.path, item.modified.path, "", "", "Original", "Modified", width, @min(height, 25), self.config.editorOptions(item), .{
                    .original = item.original,
                    .modified = item.modified,
                    .view_model = &item.diffEditorViewModel,
                }, null);
                const editor = binding.editor.?;
                editor.attachWindow(self.queue);
                editor.setThemeColors(self.config.theme);
                if (self.host.configure_diff) |configure| try configure(self.host.context, editor);
                if (item.lastTemplateData.selections) |selections| try editor.modified_editor.setSelections(selections);
                binding.original_size_listener = try editor.original_editor.viewLayout().onDidContentSizeChange().listen(binding, Binding.onContentSizeChanged);
                binding.modified_size_listener = try editor.modified_editor.viewLayout().onDidContentSizeChange().listen(binding, Binding.onContentSizeChanged);
                binding.observeHeight();
                binding.flushHeight();
            }
            binding.options_listener = try item.on_did_change_options.listen(binding, Binding.onOptionsChanged);
            try self.updateHeader(item);
            return binding;
        }
    };
}
