// Port of `src/vs/editor/browser/widget/multiDiffEditor/diffEditorItemTemplate.ts`.
// A pooled header DOM surface and clipped body frame replace absolutely
// positioned browser elements. The pooled template owns one reusable diff
// widget and its two code editor widgets; only their model-bound Views and
// feature registrations attach/detach with the item-owned models.
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
const actions_mod = @import("../../../../platform/actions/common/actions.zig");
const menu_mod = @import("../../../../platform/actions/common/menuService.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const context_menu = @import("../../../../platform/contextview/browser/contextMenuService.zig");
const command_mod = @import("../../../../platform/commands/common/commands.zig");
const IAction = @import("../../../../base/common/actions.zig").IAction;
const SignalSubscription = @import("../../../../base/common/event.zig").SignalSubscription;
const diff_vm = @import("../diffEditor/diffEditorViewModel.zig");
const hide_regions = @import("../diffEditor/features/hideUnchangedRegionsFeature.zig");

const symbol_highlight_options = blk: {
    var options = model_types.ModelDecorationOptions.init("symbol-navigate-action-highlight", .NeverGrowsWhenTypingAtEdges);
    options.className = "symbolHighlight";
    options.inlineClassName = "symbolHighlight";
    break :blk options;
};

pub const binaryFilePlaceholderContentHeight: usize = 5;
pub const ItemAction = enum { collapse, open_file, open_binary_diff, toolbar_action };
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
        pub const FileToolbarHost = struct {
            menus: *menu_mod.MenuService,
            parent_context: *const contextkey.IContextKeyService,
            context_menu_service: ?context_menu.IContextMenuService = null,
        };
        pub const Host = struct {
            context: *anyopaque,
            view_factory: *const fn (Allocator, *Editor) anyerror!*View,
            configure_diff: ?*const fn (*anyopaque, *Widget) anyerror!void = null,
            dispose_diff: ?*const fn (*anyopaque, *Widget) void = null,
            open_file: ?*const fn (*anyopaque, std.Uri) anyerror!void = null,
            open_binary_diff: ?*const fn (*anyopaque, std.Uri, std.Uri) anyerror!void = null,
            file_toolbar: ?FileToolbarHost = null,
        };
        allocator: Allocator,
        io: std.Io,
        config: *Configuration,
        host: Host,
        queue: *dispatch.Queue,
        virtualized_template: vm.VirtualizedItemTemplate(model.DocumentDiffItemViewModel, Binding),
        header: ui.Surface,
        editor: *Widget,
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
            editor_focus_listener: ?SignalSubscription = null,
            toolbar_menu: ?*menu_mod.Menu = null,
            toolbar_listener: ?SignalSubscription = null,
            item_context_listener: ?SignalSubscription = null,
            source_context_listener: ?SignalSubscription = null,
            region_context_listener: ?SignalSubscription = null,
            toolbar_buttons: []ToolbarButton = &.{},
            pending_toolbar_index: ?usize = null,
            overflow_open: bool = false,

            const ToolbarButton = struct {
                binding: *Binding,
                index: usize,
                node: *ui.Node = undefined,
                enabled: bool = false,
            };
            const overflow_index = std.math.maxInt(usize);

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
                if (self.template.header.doc.focusedElement() == self.template.root) try self.template.root.addClass(css.Class.header_focused);
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
            fn onFocusedSideChanged(_: @import("../diffEditor/diffEditorWidget.zig").Side, self: *Binding) !void {
                try self.context.notifyControlChanged();
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
            const EditorAnchor = struct {
                binding: *Binding,
                original: bool,
                line: usize,
                update: hide_regions.ScrollAnchorUpdate,

                fn getItemOffset(context: *anyopaque) usize {
                    const self: *EditorAnchor = @ptrCast(@alignCast(context));
                    const binding = self.binding;
                    const widget = binding.editor orelse return binding.template.config.outerHeight();
                    const editor = if (self.original) widget.original_editor else widget.modified_editor;
                    const top = if (self.line > editor.model.getLineCount())
                        editor.viewLayout().getContentHeight()
                    else blk: {
                        const pos = editor.viewPositionOfModelPosition(.{ .lineNumber = self.line, .column = 1 });
                        break :blk editor.viewLayout().getVerticalOffsetForLineNumber(pos.lineNumber, false);
                    };
                    return binding.template.config.outerHeight() + @as(usize, @intFromFloat(@max(0, top)));
                }
                fn apply(context: *anyopaque) !void {
                    const self: *EditorAnchor = @ptrCast(@alignCast(context));
                    try self.update.run(self.update.context);
                    // The outer scroll transaction must see the new content
                    // height before it maps the semantic line anchor.
                    self.binding.observeHeight();
                    self.binding.flushHeight();
                    try self.binding.context.notifyChanged();
                }
            };
            fn runWithEditorAnchor(self: *Binding, original: bool, line: usize, update: hide_regions.ScrollAnchorUpdate) !void {
                var anchor: EditorAnchor = .{ .binding = self, .original = original, .line = line, .update = update };
                try self.context.runWithScrollAnchor(.{ .context = &anchor, .get = EditorAnchor.getItemOffset }, .{ .context = &anchor, .run = EditorAnchor.apply });
            }
            fn runWithOriginalEditorScrollAnchor(context: *anyopaque, line: usize, update: hide_regions.ScrollAnchorUpdate) !void {
                const self: *Binding = @ptrCast(@alignCast(context));
                try self.runWithEditorAnchor(true, line, update);
            }
            fn runWithModifiedEditorScrollAnchor(context: *anyopaque, line: usize, update: hide_regions.ScrollAnchorUpdate) !void {
                const self: *Binding = @ptrCast(@alignCast(context));
                try self.runWithEditorAnchor(false, line, update);
            }
            fn toolbarContext(self: *Binding) contextkey.IContext {
                return .{ .context = self, .get_value = toolbarContextValue };
            }
            fn toolbarContextValue(context: *anyopaque, key: []const u8) contextkey.ContextKeyValue {
                const self: *Binding = @ptrCast(@alignCast(context));
                if (std.mem.eql(u8, key, "inMultiDiffEditor")) return .{ .boolean = true };
                if (std.mem.eql(u8, key, "activeEditor")) return .{ .string = "multiDiffEditor" };
                if (std.mem.eql(u8, key, "multiDiffEditorItemAllUnchangedRegionsShown")) {
                    const all_shown = for (self.item.diffEditorViewModel.unchangedRegions()) |region| {
                        if (!region.getHiddenModifiedRange().isEmpty()) break false;
                    } else true;
                    return .{ .boolean = all_shown };
                }
                if (self.item.documentDiffItem.context_keys.get(key)) |value| return value;
                if (self.item.owner.model.getContextKey(key)) |value| return value;
                return if (self.template.host.file_toolbar) |host| host.parent_context.getContextKeyValue(key) else .undefined_value;
            }
            fn mountToolbar(self: *Binding) !void {
                const host = self.template.host.file_toolbar orelse return;
                const allocator = self.template.allocator;
                self.toolbar_menu = try host.menus.createMenuWithOptions(allocator, actions_mod.menu_ids.MultiDiffEditorFileToolbar, self.toolbarContext(), .{ .should_forward_args = true });
                self.toolbar_listener = try self.toolbar_menu.?.onDidChange.listenDisposable(self, onToolbarChanged);
                self.item_context_listener = try self.item.documentDiffItem.onContextKeysDidChange.listenDisposable(self, onToolbarContextChanged);
                if (self.item.owner.model.on_did_change_context_keys) |changed| self.source_context_listener = try changed.listenDisposable(self, onToolbarContextChanged);
                self.region_context_listener = try self.item.diffEditorViewModel.on_did_change_unchanged_regions.listenDisposable(self, onRegionsChanged);
                try self.rebuildToolbar();
            }
            fn onRegionsChanged(_: diff_vm.UnchangedRegionsChange, self: *Binding) !void {
                try onToolbarContextChanged({}, self);
            }
            fn onToolbarContextChanged(_: void, self: *Binding) !void {
                if (self.toolbar_menu) |menu| try menu.refresh();
                try self.rebuildToolbar();
            }
            fn onToolbarChanged(_: void, self: *Binding) !void {
                try self.rebuildToolbar();
            }
            fn isVisibleAction(action: IAction) bool {
                return if (menu_mod.MenuItemAction.from(action)) |item| !item.hidden else true;
            }
            fn isPrimary(group: menu_mod.MenuGroup) bool {
                return std.mem.startsWith(u8, group.id, "navigation");
            }
            fn actionGlyph(action: IAction) []const u8 {
                const menu_item = menu_mod.MenuItemAction.from(action) orelse return "•";
                const icon = menu_item.item.icon orelse return "•";
                if (std.mem.eql(u8, icon, "go-to-file")) return "↗";
                if (std.mem.eql(u8, icon, "check")) return "✓";
                if (std.mem.eql(u8, icon, "plus") or std.mem.eql(u8, icon, "add")) return "+";
                if (std.mem.eql(u8, icon, "trash")) return "×";
                if (std.mem.eql(u8, icon, "arrow-right")) return "→";
                return "•";
            }
            fn rebuildToolbar(self: *Binding) !void {
                const menu = self.toolbar_menu orelse return;
                const allocator = self.template.allocator;
                // Preserve the action bar's focus across a menu rebuild.
                const focused = self.template.header.doc.focusedElement();
                const previous_index = for (self.toolbar_buttons) |button| {
                    if (focused == button.node) break @as(?usize, button.index);
                } else null;
                // Remove DOM listeners before releasing their button contexts.
                self.template.actions.clearChildren();
                allocator.free(self.toolbar_buttons);
                self.toolbar_buttons = &.{};
                self.pending_toolbar_index = null;
                var count: usize = 0;
                var has_secondary = false;
                for (menu.getActions()) |group| for (group.actions) |action| {
                    if (!isVisibleAction(action)) continue;
                    if (isPrimary(group)) count += 1 else has_secondary = true;
                };
                const show_overflow = has_secondary and self.template.host.file_toolbar.?.context_menu_service != null;
                self.toolbar_buttons = try allocator.alloc(ToolbarButton, count + @as(usize, @intFromBool(show_overflow)));
                var index: usize = 0;
                var raw_index: usize = 0;
                for (menu.getActions()) |group| for (group.actions) |action| {
                    defer raw_index += 1;
                    if (!isVisibleAction(action) or !isPrimary(group)) continue;
                    self.toolbar_buttons[index] = .{ .binding = self, .index = raw_index };
                    try self.addToolbarButton(&self.toolbar_buttons[index], actionGlyph(action), action.label(), action.enabled(), action.checked() orelse false);
                    index += 1;
                };
                if (show_overflow) {
                    self.toolbar_buttons[index] = .{ .binding = self, .index = overflow_index };
                    try self.addToolbarButton(&self.toolbar_buttons[index], "…", "More Actions", true, false);
                }
                self.template.actions.setStyle(.{ .display = if (self.toolbar_buttons.len > 0) .flex else .none });
                var first: ?*ToolbarButton = null;
                var previous: ?*ToolbarButton = null;
                for (self.toolbar_buttons) |*button| {
                    if (!button.enabled) continue;
                    if (first == null) first = button;
                    if (previous_index == button.index) previous = button;
                }
                if (previous orelse first) |button| {
                    self.setToolbarTabStop(button);
                    if (previous_index != null) _ = button.node.focus();
                } else if (previous_index != null) {
                    _ = self.template.collapse_button.focus();
                }
            }
            fn addToolbarButton(self: *Binding, button: *ToolbarButton, glyph: []const u8, label: []const u8, enabled: bool, checked: bool) !void {
                const node = try self.template.actions.document.createElement(.span);
                errdefer self.template.actions.document.destroy(node);
                try node.setTextContent(glyph);
                try node.setAttribute("role", "button");
                try node.setAttribute("aria-label", label);
                try node.setAttribute("aria-disabled", if (enabled) "false" else "true");
                button.node = node;
                button.enabled = enabled;
                node.asElement().focusable = enabled;
                node.asElement().tab_index = -1;
                node.setStyle(.{ .width = .{ .cells = 3 }, .text_align = .center, .pointer = if (enabled) .pointer else .default, .bold = checked, .dim = !enabled });
                try node.addEventListener(.{ .context = button, .mouse_down = toolbarButtonClick, .key_down = toolbarButtonKey, .focus = toolbarButtonFocused, .blur = actionBlurred });
                _ = try self.template.actions.appendChild(node);
            }
            fn setToolbarTabStop(self: *Binding, selected: *ToolbarButton) void {
                for (self.toolbar_buttons) |*button| button.node.asElement().tab_index = if (button == selected and button.enabled) 0 else -1;
            }
            fn toolbarButtonFocused(context: ?*anyopaque, event: *ui.FocusEvent) void {
                const button: *ToolbarButton = @ptrCast(@alignCast(context.?));
                button.binding.setToolbarTabStop(button);
                actionFocused(null, event);
            }
            fn toolbarButtonClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
                const button: *ToolbarButton = @ptrCast(@alignCast(context.?));
                if (event.button != .left) return;
                if (button.enabled) {
                    _ = button.node.focus();
                    button.binding.pending_toolbar_index = button.index;
                    button.binding.template.pending_action = .toolbar_action;
                }
                event.preventDefault();
                event.stopPropagation();
            }
            /// MenuWorkbenchToolBar's ActionBar uses one tab stop and arrow,
            /// Home/End navigation among enabled actions. Terminals deliver
            /// key-down only, so Enter and Space activate on key-down.
            fn toolbarButtonKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
                const button: *ToolbarButton = @ptrCast(@alignCast(context.?));
                if (event.mods.alt or event.mods.ctrl) return;
                const binding = button.binding;
                if (isActivationKey(event)) {
                    if (button.enabled) {
                        binding.pending_toolbar_index = button.index;
                        binding.template.pending_action = .toolbar_action;
                    }
                } else switch (event.key) {
                    .left, .right, .home, .end => {
                        const buttons = binding.toolbar_buttons;
                        if (buttons.len == 0) return;
                        const current = for (buttons, 0..) |*candidate, index| {
                            if (candidate == button) break index;
                        } else return;
                        const forward = event.key == .right or event.key == .home;
                        const start = switch (event.key) {
                            .home => 0,
                            .end => buttons.len - 1,
                            .left => (current + buttons.len - 1) % buttons.len,
                            .right => (current + 1) % buttons.len,
                            else => unreachable,
                        };
                        for (0..buttons.len) |offset| {
                            const index = if (forward) (start + offset) % buttons.len else (start + buttons.len - offset) % buttons.len;
                            if (!buttons[index].enabled) continue;
                            _ = buttons[index].node.focus();
                            break;
                        }
                    },
                    else => return,
                }
                event.preventDefault();
                event.stopPropagation();
            }
            fn toolbarUri(self: *Binding) std.Uri {
                const item = self.item.documentDiffItem;
                return (item.modified orelse item.original.?).uri;
            }
            pub fn runToolbarAction(self: *Binding, anchor: context_menu.Anchor) !void {
                const selected = self.pending_toolbar_index orelse return;
                self.pending_toolbar_index = null;
                if (selected == overflow_index) return self.showToolbarOverflow(anchor);
                const menu = self.toolbar_menu orelse return;
                var raw_index: usize = 0;
                for (menu.getActions()) |group| for (group.actions) |action| {
                    defer raw_index += 1;
                    if (raw_index != selected or !isVisibleAction(action) or !action.enabled()) continue;
                    const item = menu_mod.MenuItemAction.from(action) orelse return;
                    const uri = self.toolbarUri();
                    try item.runWithArgument(command_mod.CommandArgument.from(std.Uri, &uri));
                    return;
                };
            }
            const Overflow = struct {
                binding: *Binding,
                commands: *command_mod.CommandRegistry,
                uri: std.Uri,
                fn run(self: *Overflow, id: []const u8) !void {
                    _ = try self.commands.executeWithArgument(id, command_mod.CommandArgument.from(std.Uri, &self.uri));
                }
                fn hide(context: *anyopaque) void {
                    const self: *Overflow = @ptrCast(@alignCast(context));
                    self.binding.overflow_open = false;
                }
            };
            fn showToolbarOverflow(self: *Binding, anchor: context_menu.Anchor) !void {
                const host = self.template.host.file_toolbar orelse return;
                const service = host.context_menu_service orelse return;
                const commands = host.menus.command_registry orelse return;
                const menu = self.toolbar_menu orelse return;
                const popup = try context_menu.Menu.init(self.template.allocator, Overflow{ .binding = self, .commands = commands, .uri = undefined }, Overflow.run);
                errdefer popup.deinit();
                popup.on_hide = Overflow.hide;
                const a = popup.arena.allocator();
                popup.getActionsContext(Overflow).?.uri = try std.Uri.parse(try std_uri.encodedResource(a, self.toolbarUri()));
                for (menu.getActions()) |group| {
                    if (isPrimary(group)) continue;
                    var first = true;
                    for (group.actions) |action| {
                        if (!isVisibleAction(action)) continue;
                        if (first and popup.items.items.len > 0) try popup.separator();
                        first = false;
                        try popup.add(try a.dupe(u8, action.id()), .{ .label = try a.dupe(u8, action.label()), .enabled = action.enabled() });
                    }
                }
                if (popup.items.items.len == 0) {
                    popup.deinit();
                    return;
                }
                try service.showContextMenu(popup, anchor);
                self.overflow_open = true;
            }
            fn unmountToolbar(self: *Binding) void {
                if (self.overflow_open) if (self.template.host.file_toolbar) |host| if (host.context_menu_service) |service| service.hideContextMenu();
                if (self.toolbar_listener) |listener| listener.dispose();
                if (self.item_context_listener) |listener| listener.dispose();
                if (self.source_context_listener) |listener| listener.dispose();
                if (self.region_context_listener) |listener| listener.dispose();
                if (self.toolbar_menu) |menu| {
                    self.template.actions.clearChildren();
                    self.template.allocator.free(self.toolbar_buttons);
                    self.toolbar_buttons = &.{};
                    menu.deinit();
                    self.template.allocator.destroy(menu);
                    self.toolbar_menu = null;
                }
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
                self.unmountToolbar();
                if (self.editor_focus_listener) |listener| listener.dispose();
                if (self.options_listener) |id| self.item.on_did_change_options.unlisten(id);
                if (self.editor) |editor| {
                    if (self.original_size_listener) |id| editor.original_editor.viewLayout().onDidContentSizeChange().unlisten(id);
                    if (self.modified_size_listener) |id| editor.modified_editor.viewLayout().onDidContentSizeChange().unlisten(id);
                    if (self.template.host.dispose_diff) |dispose| dispose(self.template.host.context, editor);
                    editor.setDiffModel(null) catch {};
                    self.editor = null;
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
            pub fn hasHeaderFocus(self: *const Binding) bool {
                return self.template.header.doc.focusedElement() != null;
            }
            pub fn blurHeader(self: *Binding) void {
                self.template.header.doc.blur();
            }
            fn firstHeaderStop(self: *Binding) *ui.Node {
                return if (self.template.config.variant.headerClickToCollapse) self.template.root else self.template.collapse_button;
            }
            fn lastHeaderStop(self: *Binding) *ui.Node {
                for (self.toolbar_buttons) |button| {
                    if (button.enabled and button.node.asElement().tab_index == 0) return button.node;
                }
                if (self.template.host.file_toolbar == null and self.template.host.open_file != null) return self.template.actions;
                return self.template.collapse_button;
            }
            pub fn focusHeader(self: *Binding, last: bool) bool {
                return (if (last) self.lastHeaderStop() else self.firstHeaderStop()).focus();
            }
            pub const HeaderKeyResult = struct {
                handled: bool = false,
                action: ?ItemAction = null,
                leave: ?ui.dom.FocusDirection = null,
            };
            pub fn dispatchHeaderKey(self: *Binding, event: *ui.KeyEvent) HeaderKeyResult {
                const template = self.template;
                const focused = template.header.doc.focusedElement() orelse return .{};
                const tab = !event.mods.ctrl and !event.mods.alt and (event.key == .tab or event.key == .backtab);
                if (tab) {
                    const backward = event.key == .backtab or event.mods.shift;
                    // A retained header is a separate terminal surface. At its
                    // tab boundary the composite moves focus to the adjacent
                    // editor/item instead of wrapping inside the subdocument.
                    if (backward and focused == self.firstHeaderStop()) return .{ .leave = .backward };
                    if (!backward and focused == self.lastHeaderStop()) return .{ .leave = .forward };
                }
                template.header.doc.dispatchEvent(event);
                const action = template.pending_action;
                template.pending_action = null;
                return .{ .handled = event.default_prevented or tab, .action = action };
            }
            pub fn keyboardToolbarAnchor(self: *Binding, x: usize, y: usize) context_menu.Anchor {
                const node = self.template.header.doc.focusedElement() orelse self.template.actions;
                const rect = node.asElement().rect;
                return .{ .x = x + ui.cell.snap(rect.x), .y = y + (self.headerRange().start -| self.rendered_viewport.start) + ui.cell.snap(rect.y) };
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
            /// The binary placeholder is focusable, but only its Open Diff
            /// button invokes the action on pointer input.
            pub fn binaryActionHit(self: *Binding, x: usize, absolute_row: usize) bool {
                if (self.editor != null or self.item.collapsed or self.template.host.open_binary_diff == null or self.item.documentDiffItem.original == null or self.item.documentDiffItem.modified == null) return false;
                const body = self.bodyRange();
                if (!body.contains(absolute_row) or body.length() == 0) return false;
                const insets = self.template.config.variant.horizontalInsets;
                const width = self.width -| insets.left -| insets.right;
                const label = "Open Diff";
                const left = insets.left + (width -| label.len) / 2;
                const right = @min(left + label.len, insets.left + width);
                return absolute_row == body.start + @min(body.length() - 1, body.length() / 2 + 1) and x >= left and x < right;
            }
            pub fn pointerAt(self: *Binding, x: usize, absolute_row: usize) !ui.Pointer {
                const header = self.headerRange();
                if (header.contains(absolute_row)) return (try self.template.header.pointerAt(x, absolute_row - header.start)) orelse .default;
                const body = self.bodyRange();
                if (body.contains(absolute_row)) {
                    if (self.editor) |editor| return editor.pointerAt(x -| self.template.config.variant.horizontalInsets.left, absolute_row - body.start);
                    if (self.binaryActionHit(x, absolute_row)) return .pointer;
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
                .editor = undefined,
            };
            errdefer self.header.deinit();
            errdefer self.virtualized_template.deinit();
            try self.buildHeader();
            self.editor = try Widget.createDetached(host.view_factory, allocator, io, config.width, 1, .{});
            self.editor.attachWindow(queue);
            return self;
        }
        pub fn destroy(self: *Self) void {
            self.virtualized_template.deinit();
            self.editor.destroy();
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
            self.root.asElement().focusable = self.config.variant.headerClickToCollapse;
            if (self.config.variant.headerClickToCollapse) try self.root.setAttribute("role", "button");
            try self.root.addEventListener(.{ .context = self, .key_down = headerKey, .focus = headerFocused, .blur = headerBlurred });
            self.row = try element(self.root, .header_content, .div);
            self.collapse_button = try element(self.row, .collapse_button, .span);
            try self.collapse_button.setAttribute("role", "button");
            try self.collapse_button.setAttribute("aria-label", "Collapse or expand file");
            self.collapse_button.asElement().focusable = true;
            try self.collapse_button.addEventListener(.{ .context = self, .mouse_down = collapseClick, .key_down = collapseKey, .focus = actionFocused, .blur = actionBlurred });
            const file_path = try element(self.row, .file_path, .div);
            self.primary_path = try element(file_path, .title, .span);
            self.status = try element(file_path, .status, .span);
            self.secondary_path = try element(file_path, .title, .span);
            self.actions = try element(self.row, .actions, .span);
            if (self.host.file_toolbar == null) {
                try self.actions.setTextContent("↗");
                try self.actions.setAttribute("role", "button");
                try self.actions.setAttribute("aria-label", "Go to File");
                self.actions.asElement().focusable = self.host.open_file != null;
                try self.actions.addEventListener(.{ .context = self, .mouse_down = openFileClick, .key_down = openFileKey, .focus = actionFocused, .blur = actionBlurred });
            }
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
            if (self.host.file_toolbar == null) self.actions.setStyle(.{ .display = if (self.host.open_file != null) .flex else .none });
        }
        fn collapseClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            if (event.button == .left) {
                _ = self.collapse_button.focus();
                self.pending_action = .collapse;
                event.preventDefault();
                event.stopPropagation();
            }
        }
        fn openFileClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            if (event.button == .left) {
                _ = self.actions.focus();
                self.pending_action = .open_file;
                event.preventDefault();
                event.stopPropagation();
            }
        }
        fn headerClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            if (event.button == .left and self.config.variant.headerClickToCollapse) {
                _ = self.root.focus();
                self.pending_action = .collapse;
                event.preventDefault();
            }
        }
        fn isActivationKey(event: *const ui.KeyEvent) bool {
            if (event.mods.ctrl or event.mods.alt) return false;
            return switch (event.key) {
                .enter => true,
                .char => |value| value == ' ',
                .text => |value| std.mem.eql(u8, value, " "),
                else => false,
            };
        }
        fn collapseKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
            if (!isActivationKey(event)) return;
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.pending_action = .collapse;
            event.preventDefault();
            event.stopPropagation();
        }
        fn openFileKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
            if (!isActivationKey(event)) return;
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.pending_action = .open_file;
            event.preventDefault();
            event.stopPropagation();
        }
        fn headerKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            // Child action and disclosure listeners consume their own keys.
            if (self.config.variant.headerClickToCollapse and event.target == self.root and isActivationKey(event)) collapseKey(context, event);
        }
        fn actionFocused(_: ?*anyopaque, event: *ui.FocusEvent) void {
            if (event.target) |node| node.addClass(css.Class.focused_action) catch {};
        }
        fn actionBlurred(_: ?*anyopaque, event: *ui.FocusEvent) void {
            if (event.target) |node| node.removeClass(css.Class.focused_action);
        }
        fn headerFocused(_: ?*anyopaque, event: *ui.FocusEvent) void {
            if (event.target) |node| node.addClass(css.Class.header_focused) catch {};
        }
        fn headerBlurred(_: ?*anyopaque, event: *ui.FocusEvent) void {
            if (event.target) |node| node.removeClass(css.Class.header_focused);
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
                const editor = self.editor;
                std.debug.assert(!editor.hasModel());
                try editor.setDiffModel(.{
                    .original = item.original,
                    .modified = item.modified,
                    .original_path = item.original.path,
                    .modified_path = item.modified.path,
                    .options = self.config.editorOptions(item),
                    .width = width,
                    .height = @min(height, 25),
                    .view_model = &item.diffEditorViewModel,
                });
                binding.editor = editor;
                editor.setScrollAnchors(.{ .context = binding, .run = Binding.runWithOriginalEditorScrollAnchor }, .{ .context = binding, .run = Binding.runWithModifiedEditorScrollAnchor });
                editor.setThemeColors(self.config.theme);
                if (self.host.configure_diff) |configure| try configure(self.host.context, editor);
                if (item.lastTemplateData.selections) |selections| try editor.modified_editor.setSelections(selections);
                binding.original_size_listener = try editor.original_editor.viewLayout().onDidContentSizeChange().listen(binding, Binding.onContentSizeChanged);
                binding.modified_size_listener = try editor.modified_editor.viewLayout().onDidContentSizeChange().listen(binding, Binding.onContentSizeChanged);
                binding.editor_focus_listener = try editor.on_did_change_focused_side.listenDisposable(binding, Binding.onFocusedSideChanged);
                binding.observeHeight();
                binding.flushHeight();
            }
            binding.options_listener = try item.on_did_change_options.listen(binding, Binding.onOptionsChanged);
            try self.updateHeader(item);
            try binding.mountToolbar();
            return binding;
        }
    };
}
