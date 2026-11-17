// Port of `src/vs/editor/contrib/hover/browser/contentHoverWidgetWrapper.ts`.
//
// The wrapper owns the hover operation, the anchor candidates and the terminal
// content widget. Mouse/keyboard routing stays in `contentHoverController.zig`.
// Async hover computation is synchronous in this port, so the "Loading..."
// message path never produces a visible row.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Range = @import("../../../common/core/range.zig").Range;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

const hoverTypes = @import("./hoverTypes.zig");
const EditorMouseEvent = hoverTypes.EditorMouseEvent;
const HoverAnchor = hoverTypes.HoverAnchor;
const HoverRangeAnchor = hoverTypes.HoverRangeAnchor;
const HoverStartSource = hoverTypes.HoverStartSource;
const IHoverPart = hoverTypes.IHoverPart;
const IEditorHoverParticipant = hoverTypes.IEditorHoverParticipant;
const ContentHoverResult = @import("./contentHoverTypes.zig").ContentHoverResult;
const ContentHoverComputer = @import("./contentHoverComputer.zig").ContentHoverComputer;
const ContentHoverComputerOptions = @import("./contentHoverComputer.zig").ContentHoverComputerOptions;
const hoverOperation = @import("./hoverOperation.zig");
const HoverOperation = hoverOperation.HoverOperation;
const HoverStartMode = hoverOperation.HoverStartMode;
const HoverResult = hoverOperation.HoverResult;
const RenderedContentHover = @import("./contentHoverRendered.zig").RenderedContentHover;
const HoverCoordinatesHost = @import("./contentHoverRendered.zig").HoverCoordinatesHost;
const RenderHost = @import("./contentHoverRendered.zig").RenderHost;
const ContentHoverWidget = @import("./contentHoverWidget.zig").ContentHoverWidget;
const editorBrowser = @import("../../../browser/editorBrowser.zig");
const ContentHoverWidgetHost = @import("./contentHoverWidget.zig").ContentHoverWidgetHost;

pub const HoverWidgetWrapperHost = struct {
    context: *anyopaque,
    /// Facts about the editor the widget needs (height, visible rows).
    widget: ContentHoverWidgetHost,
    coordinates: HoverCoordinatesHost,
    /// Repaint request; the TUI event loop owns when a frame is drawn.
    request_frame: *const fn (context: *anyopaque) void,
    /// Hides through the controller so its current result is cleared too.
    hide: *const fn (context: *anyopaque) void,
    /// Restores editor focus after a focused hover is dismissed.
    focus_editor: *const fn (context: *anyopaque) void,
    /// Publishes or clears the `hoverHighlight` model decoration.
    set_hover_decoration: *const fn (context: *anyopaque, range: ?Range) void,
};

pub const ContentHoverWidgetWrapper = struct {
    allocator: Allocator,
    model: *TextModel,
    participants: []IEditorHoverParticipant,
    host: HoverWidgetWrapperHost,
    sticky: bool,
    widget: *ContentHoverWidget,
    computer: ContentHoverComputer,
    operation: HoverOperation(ContentHoverComputerOptions, IHoverPart),
    current_result: ?ContentHoverResult = null,

    pub fn init(
        allocator: Allocator,
        model: *TextModel,
        participants: []const IEditorHoverParticipant,
        host: HoverWidgetWrapperHost,
        sticky: bool,
        operation_timer: hoverOperation.Timer,
    ) !*ContentHoverWidgetWrapper {
        const self = try allocator.create(ContentHoverWidgetWrapper);
        errdefer allocator.destroy(self);

        const sorted = try allocator.dupe(IEditorHoverParticipant, participants);
        errdefer allocator.free(sorted);
        std.mem.sort(IEditorHoverParticipant, sorted, {}, lessThanOrdinal);

        self.* = .{
            .allocator = allocator,
            .model = model,
            .participants = sorted,
            .host = host,
            .sticky = sticky,
            .widget = undefined,
            .computer = ContentHoverComputer.init(allocator, model, sorted),
            .operation = undefined,
            .current_result = null,
        };
        errdefer self.computer.deinit();

        self.widget = try ContentHoverWidget.init(allocator, host.widget);
        errdefer self.widget.deinit();

        self.operation = HoverOperation(ContentHoverComputerOptions, IHoverPart).init(
            allocator,
            .{
                .context = self,
                .compute_async = computeAsyncOperation,
                .compute_sync = computeSyncOperation,
            },
            operation_timer,
            onOperationResult,
            self,
        );
        return self;
    }

    pub fn deinit(self: *ContentHoverWidgetWrapper) void {
        self.hide();
        self.operation.deinit();
        self.widget.deinit();
        self.computer.deinit();
        self.allocator.free(self.participants);
        self.allocator.destroy(self);
    }

    fn lessThanOrdinal(_: void, left: IEditorHoverParticipant, right: IEditorHoverParticipant) bool {
        return left.hover_ordinal < right.hover_ordinal;
    }

    fn computeAsyncOperation(
        context: *anyopaque,
        options: *const ContentHoverComputerOptions,
        token: CancellationToken,
    ) anyerror![]const IHoverPart {
        const self: *ContentHoverWidgetWrapper = @ptrCast(@alignCast(context));
        return self.computer.computeAsync(options.*, token);
    }

    fn computeSyncOperation(context: *anyopaque, options: *const ContentHoverComputerOptions) anyerror![]const IHoverPart {
        const self: *ContentHoverWidgetWrapper = @ptrCast(@alignCast(context));
        return self.computer.computeSync(options.*);
    }

    fn onOperationResult(context: *anyopaque, result: HoverResult(ContentHoverComputerOptions, IHoverPart)) void {
        const self: *ContentHoverWidgetWrapper = @ptrCast(@alignCast(context));
        self.withResult(result);
    }

    fn withResult(self: *ContentHoverWidgetWrapper, result: HoverResult(ContentHoverComputerOptions, IHoverPart)) void {
        const previous_visible_complete = self.current_result != null and
            self.current_result.?.is_complete and
            self.widget.isVisible();
        var applied = false;
        if (!previous_visible_complete) {
            self.setCurrentResult(result.value, result.is_complete, result.options);
            applied = true;
        }
        if (!result.is_complete) return;
        if (result.value.len == 0 and result.options.insist_on_keeping_hover_visible) return;
        // Upstream compares the result by identity; a result that was already
        // applied above must not be rendered twice (that would reset scroll and
        // focus on every frame of a single-timer result).
        if (!applied) self.setCurrentResult(result.value, result.is_complete, result.options);
    }

    fn setCurrentResult(
        self: *ContentHoverWidgetWrapper,
        parts: []const IHoverPart,
        is_complete: bool,
        options: ContentHoverComputerOptions,
    ) void {
        self.clearCurrentResult();
        if (parts.len == 0) {
            self.hideHover();
            return;
        }
        const result = ContentHoverResult.init(self.allocator, parts, is_complete, options) catch {
            self.hideHover();
            return;
        };
        self.current_result = result;
        self.showHover();
    }

    fn clearCurrentResult(self: *ContentHoverWidgetWrapper) void {
        if (self.current_result) |*result| {
            result.deinit();
            self.current_result = null;
        }
    }

    fn showHover(self: *ContentHoverWidgetWrapper) void {
        const result = &(self.current_result orelse return);
        const render_host = RenderHost{
            .context = self,
            .hide = renderHide,
            .on_contents_changed = renderContentsChanged,
            .set_minimum_dimensions = renderSetMinimumDimensions,
            .focus = renderFocus,
        };
        const rendered = RenderedContentHover.init(
            self.allocator,
            result,
            self.participants,
            self.host.coordinates,
            render_host,
        ) catch {
            self.hideHover();
            return;
        };
        if (!rendered.hasContent()) {
            rendered.deinit();
            self.hideHover();
            return;
        }
        self.host.set_hover_decoration(self.host.context, rendered.highlight);
        self.widget.show(rendered);
        if (rendered.should_focus) self.widget.focus();
    }

    fn hideHover(self: *ContentHoverWidgetWrapper) void {
        self.widget.hide();
        self.host.set_hover_decoration(self.host.context, null);
        for (self.participants) |participant| {
            if (participant.handle_hide) |handle| handle(participant.context);
        }
    }

    fn renderHide(context: ?*anyopaque) void {
        const self: *ContentHoverWidgetWrapper = @ptrCast(@alignCast(context orelse return));
        self.host.hide(self.host.context);
    }

    fn renderContentsChanged(context: ?*anyopaque) void {
        const self: *ContentHoverWidgetWrapper = @ptrCast(@alignCast(context orelse return));
        self.host.request_frame(self.host.context);
    }

    fn renderSetMinimumDimensions(context: ?*anyopaque, width: usize, height: usize) void {
        const self: *ContentHoverWidgetWrapper = @ptrCast(@alignCast(context orelse return));
        self.widget.setMinimumDimensions(width, height);
    }

    fn renderFocus(context: ?*anyopaque) void {
        const self: *ContentHoverWidgetWrapper = @ptrCast(@alignCast(context orelse return));
        self.widget.focus();
    }

    /// Returns true when the hover shows now or will show after the delay.
    pub fn showsOrWillShow(self: *ContentHoverWidgetWrapper, mouse_event: EditorMouseEvent) bool {
        const anchor = self.findHoverAnchor(mouse_event);
        if (anchor) |value| {
            var hover_anchor = value;
            return self.startShowingOrUpdateHover(&hover_anchor, .delayed, .mouse, false, mouse_event);
        }
        return self.startShowingOrUpdateHover(null, .delayed, .mouse, false, mouse_event);
    }

    fn findHoverAnchor(self: *ContentHoverWidgetWrapper, mouse_event: EditorMouseEvent) ?HoverAnchor {
        _ = self;
        const target = mouse_event.target;
        switch (target.type) {
            .content_text => {
                const range = target.range orelse return null;
                return .{ .range = HoverRangeAnchor.init(0, range) };
            },
            .content_empty => {
                const detail = switch (target.detail orelse return null) {
                    .content_empty => |value| value,
                    .view_zone => return null,
                };
                // Upstream accepts an empty-area hover when the pointer is
                // within half a character of the text. Cells are whole units,
                // so only a zero-cell distance can qualify.
                if (detail.is_after_lines or detail.horizontal_distance_to_text != 0) return null;
                const range = target.range orelse return null;
                return .{ .range = HoverRangeAnchor.init(0, range) };
            },
            else => return null,
        }
    }

    fn startShowingOrUpdateHover(
        self: *ContentHoverWidgetWrapper,
        anchor: ?*const HoverAnchor,
        mode: HoverStartMode,
        source: HoverStartSource,
        should_focus: bool,
        mouse_event: ?EditorMouseEvent,
    ) bool {
        const visible = self.widget.isVisible() and self.current_result != null;
        if (!visible) {
            if (anchor) |value| {
                self.startHoverOperationIfNecessary(value, mode, source, should_focus, false);
                return true;
            }
            return false;
        }

        const is_mouse_getting_closer = mouse_event != null and
            mouse_event.?.target.type == .content_widget;
        if (self.sticky and is_mouse_getting_closer) {
            if (anchor) |value| {
                self.startHoverOperationIfNecessary(value, mode, source, should_focus, true);
            }
            return true;
        }

        const value = anchor orelse {
            self.clearCurrentResult();
            self.hideHover();
            return false;
        };

        const current_result = &(self.current_result.?);
        const current_anchor = &current_result.options.anchor;
        if (current_anchor.equals(value)) return true;

        const show_at = self.widget.position() orelse value.getRange().getStartPosition();
        if (!value.canAdoptVisibleHover(current_anchor, show_at)) {
            self.clearCurrentResult();
            self.hideHover();
            self.startHoverOperationIfNecessary(value, mode, source, should_focus, false);
            return true;
        }

        // Keep the parts that still apply to the new anchor. `filter` consumes
        // the previous result and returns the replacement.
        const filtered = current_result.filter(value) catch return true;
        self.current_result = filtered;
        self.showHover();
        self.startHoverOperationIfNecessary(value, mode, source, should_focus, false);
        return true;
    }

    fn startHoverOperationIfNecessary(
        self: *ContentHoverWidgetWrapper,
        anchor: *const HoverAnchor,
        mode: HoverStartMode,
        source: HoverStartSource,
        should_focus: bool,
        insist_on_keeping_hover_visible: bool,
    ) void {
        if (self.operation.options) |*current| {
            if (current.anchor.equals(anchor)) return;
        }
        self.operation.cancel();
        self.computer.beginComputation();
        self.operation.start(mode, .{
            .anchor = anchor.*,
            .source = source,
            .should_focus = should_focus,
            .insist_on_keeping_hover_visible = insist_on_keeping_hover_visible,
        });
    }

    pub fn startShowingAtRange(self: *ContentHoverWidgetWrapper, range: Range, mode: HoverStartMode, source: HoverStartSource, should_focus: bool) void {
        var anchor = HoverAnchor{ .range = HoverRangeAnchor.init(0, range) };
        _ = self.startShowingOrUpdateHover(&anchor, mode, source, should_focus, null);
    }

    pub fn hide(self: *ContentHoverWidgetWrapper) void {
        self.operation.cancel();
        self.clearCurrentResult();
        self.hideHover();
        self.widget.hide();
    }

    /// The content widget contract registered with the TUI view.
    pub fn contentWidget(self: *ContentHoverWidgetWrapper) editorBrowser.IContentWidget {
        return self.widget.interface();
    }

    pub fn isVisible(self: *const ContentHoverWidgetWrapper) bool {
        return self.widget.isVisible();
    }

    pub fn isFocused(self: *const ContentHoverWidgetWrapper) bool {
        return self.widget.isFocused();
    }

    pub fn isVisibleFromKeyboard(self: *const ContentHoverWidgetWrapper) bool {
        return self.widget.isVisibleFromKeyboard();
    }

    pub fn focusedHoverPartIndex(self: *const ContentHoverWidgetWrapper) isize {
        return self.widget.focusedHoverPartIndex();
    }

    pub fn getWidgetContent(self: *const ContentHoverWidgetWrapper) ?[]const u8 {
        return self.widget.widgetContent();
    }

    pub fn focus(self: *ContentHoverWidgetWrapper) void {
        self.widget.focus();
    }

    pub fn scrollUp(self: *ContentHoverWidgetWrapper) void {
        self.widget.scrollUp();
    }

    pub fn scrollDown(self: *ContentHoverWidgetWrapper) void {
        self.widget.scrollDown();
    }

    pub fn pageUp(self: *ContentHoverWidgetWrapper) void {
        self.widget.pageUp();
    }

    pub fn pageDown(self: *ContentHoverWidgetWrapper) void {
        self.widget.pageDown();
    }

    pub fn goToTop(self: *ContentHoverWidgetWrapper) void {
        self.widget.goToTop();
    }

    pub fn goToBottom(self: *ContentHoverWidgetWrapper) void {
        self.widget.goToBottom();
    }

    pub fn hasPendingOperation(self: *ContentHoverWidgetWrapper) bool {
        return !self.operation.isIdle();
    }
};
