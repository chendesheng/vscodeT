// Port of `src/vs/editor/contrib/hover/browser/hoverTypes.ts`.
//
// Terminal adaptation: rendered hover parts build `ui` nodes instead of DOM
// elements, so a rendered part is a small vtable (`measure`/`build`) rather
// than a ready `HTMLElement`. The hover widget needs a natural width before it
// can wrap the contents, and the DOM version gets that from CSS.
//
// `IHoverPart.data` is participant-owned. It is valid until that participant
// computes its next result; the rendered content dereferences it immediately.
const std = @import("std");
const ui = @import("ui");

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const ModelDecoration = @import("../../../common/model.zig").ModelDecoration;
const editorBrowser = @import("../../../browser/editorBrowser.zig");
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

pub const HoverStartSource = enum(u8) {
    mouse = 0,
    click = 1,
    keyboard = 2,
};

/// The portable part of upstream `IEditorMouseEvent` the hover controller
/// consumes. The terminal adapter fills the target from `View.mouseTargetAt`.
pub const EditorMouseEvent = struct {
    target: editorBrowser.MouseTarget,
    x: usize,
    y: usize,
    mods: ui.Modifiers = .{},
    button: ui.MouseButton = .none,
};

pub const HoverAnchorType = enum(u8) {
    range = 1,
    foreign_element = 2,
};

pub const HoverRangeAnchor = struct {
    priority: usize,
    range: Range,
    initial_mouse_pos_x: ?f64 = null,
    initial_mouse_pos_y: ?f64 = null,

    pub fn init(priority: usize, range: Range) HoverRangeAnchor {
        return .{ .priority = priority, .range = range };
    }
};

pub const HoverForeignElementAnchor = struct {
    priority: usize,
    owner: *const anyopaque,
    range: Range,
    initial_mouse_pos_x: ?f64 = null,
    initial_mouse_pos_y: ?f64 = null,
    supports_marker_hover: ?bool = null,
};

pub const HoverAnchor = union(enum) {
    range: HoverRangeAnchor,
    foreign_element: HoverForeignElementAnchor,

    pub fn getRange(self: *const HoverAnchor) Range {
        return switch (self.*) {
            .range => |anchor| anchor.range,
            .foreign_element => |anchor| anchor.range,
        };
    }

    pub fn getPriority(self: *const HoverAnchor) usize {
        return switch (self.*) {
            .range => |anchor| anchor.priority,
            .foreign_element => |anchor| anchor.priority,
        };
    }

    pub fn getType(self: *const HoverAnchor) HoverAnchorType {
        return switch (self.*) {
            .range => .range,
            .foreign_element => .foreign_element,
        };
    }

    pub fn equals(self: *const HoverAnchor, other: *const HoverAnchor) bool {
        return switch (self.*) {
            .range => |anchor| switch (other.*) {
                .range => |other_anchor| Range.equalsRange(anchor.range, other_anchor.range),
                .foreign_element => false,
            },
            .foreign_element => |anchor| switch (other.*) {
                .foreign_element => |other_anchor| anchor.owner == other_anchor.owner,
                .range => false,
            },
        };
    }

    pub fn canAdoptVisibleHover(self: *const HoverAnchor, last_anchor: *const HoverAnchor, show_at_position: Position) bool {
        return switch (self.*) {
            .range => |anchor| switch (last_anchor.*) {
                .range => show_at_position.lineNumber == anchor.range.startLineNumber,
                .foreign_element => false,
            },
            .foreign_element => |anchor| switch (last_anchor.*) {
                .foreign_element => |last| anchor.owner == last.owner,
                .range => false,
            },
        };
    }
};

pub const IHoverPart = struct {
    /// The creator of this hover part; compared by identity.
    owner: *const anyopaque,
    range: Range,
    force_show_at_range: bool = false,
    is_before_content: bool = false,
    /// Participant-owned payload. Valid until the participant computes again.
    data: ?*const anyopaque = null,
    is_valid_for_hover_anchor: *const fn (part: *const IHoverPart, anchor: *const HoverAnchor) bool,

    pub fn isValidForHoverAnchor(self: *const IHoverPart, anchor: *const HoverAnchor) bool {
        return self.is_valid_for_hover_anchor(self, anchor);
    }
};

/// Port of the status bar contract. The terminal implementation renders action
/// labels as a bottom row; there is no keybinding registry, so actions are
/// mouse-clickable only.
pub const HoverActionOptions = struct {
    label: []const u8,
    command_id: []const u8 = "",
    run: ?*const fn (context: ?*anyopaque) void = null,
    run_context: ?*anyopaque = null,
};

pub const IEditorHoverAction = struct {
    context: *anyopaque,
    set_enabled: *const fn (context: *anyopaque, enabled: bool) void,
};

pub const IEditorHoverStatusBar = struct {
    context: *anyopaque,
    add_action: *const fn (context: *anyopaque, options: HoverActionOptions) IEditorHoverAction,
    has_content: *const fn (context: *anyopaque) bool,
    append: *const fn (context: *anyopaque, node: *ui.Node) void,
};

/// Port of `IEditorHoverRenderContext`. Rendering is synchronous in the
/// terminal, so these callbacks forward state changes to the hover widget and
/// are normally not used while a participant renders.
pub const IEditorHoverRenderContext = struct {
    context: *anyopaque,
    /// Container for rendered hover parts. The terminal builds the parts in a
    /// later pass, so this is null while a participant renders.
    fragment: ?*ui.Node = null,
    status_bar: *const IEditorHoverStatusBar,
    hide: *const fn (context: *anyopaque) void,
    on_contents_changed: *const fn (context: *anyopaque) void,
    set_minimum_dimensions: *const fn (context: *anyopaque, width: usize, height: usize) void,
    focus: *const fn (context: *anyopaque) void,

    pub fn callHide(self: IEditorHoverRenderContext) void {
        self.hide(self.context);
    }

    pub fn callOnContentsChanged(self: IEditorHoverRenderContext) void {
        self.on_contents_changed(self.context);
    }

    pub fn callSetMinimumDimensions(self: IEditorHoverRenderContext, width: usize, height: usize) void {
        self.set_minimum_dimensions(self.context, width, height);
    }

    pub fn callFocus(self: IEditorHoverRenderContext) void {
        self.focus(self.context);
    }
};

/// A rendered hover part. Upstream exposes a ready `HTMLElement`; the terminal
/// needs the natural width first, then a `build` pass at the final width.
pub const IRenderedHoverPart = struct {
    hover_part: IHoverPart,
    context: *const anyopaque,
    /// Natural width in cells, capped at the given maximum.
    measure: *const fn (context: *const anyopaque, max_width: usize) usize,
    /// Rows the part occupies at the given content width.
    height: *const fn (context: *const anyopaque, width: usize) usize,
    /// Appends the part's rows to the hover content, starting at `top`.
    /// Returns the number of rows written.
    build: *const fn (
        context: *const anyopaque,
        doc: *ui.Document,
        parent: *ui.Node,
        width: usize,
        top: usize,
    ) anyerror!usize,
    /// Plain text equivalent for the accessible view.
    accessible_content: []const u8 = "",
    can_increase_verbosity: bool = false,
    can_decrease_verbosity: bool = false,
};

pub const HoverVerbosityAction = @import("../../../common/languages.zig").HoverVerbosityAction;
pub const HoverVerbosityListener = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, IHoverPart, IHoverPart, bool) void,
};

/// Port of `IEditorHoverParticipant`, with the terminal rendering contract.
/// The returned slices and `IRenderedHoverPart` values are owned by the
/// participant and stay valid until its next compute/render call.
pub const IEditorHoverParticipant = struct {
    context: *anyopaque,
    hover_ordinal: i32,
    hide_copy_button: ?bool = null,
    compute_sync: ?*const fn (
        context: *anyopaque,
        anchor: *const HoverAnchor,
        line_decorations: []const ModelDecoration,
        source: HoverStartSource,
    ) []const IHoverPart = null,
    /// Promise/async-iterable continuation for participant results. The
    /// disposable detaches emissions and completion when the hover is hidden.
    request_async: ?*const fn (*anyopaque, *const HoverAnchor, []const ModelDecoration, HoverStartSource, CancellationToken, @import("hoverOperation.zig").AsyncResultSink(IHoverPart)) anyerror!?@import("../../../../base/common/lifecycle.zig").IDisposable = null,
    /// Immediate completion for a participant that does not require I/O.
    compute_async: ?*const fn (
        context: *anyopaque,
        anchor: *const HoverAnchor,
        line_decorations: []const ModelDecoration,
        source: HoverStartSource,
        token: CancellationToken,
    ) []const IHoverPart = null,
    create_loading_message: ?*const fn (context: *anyopaque, anchor: *const HoverAnchor) ?IHoverPart = null,
    render_hover_parts: ?*const fn (
        context: *anyopaque,
        render_context: *const IEditorHoverRenderContext,
        hover_parts: []const IHoverPart,
    ) anyerror![]const IRenderedHoverPart = null,
    get_accessible_content: ?*const fn (context: *anyopaque, hover_part: *const IHoverPart) []const u8 = null,
    supports_verbosity: ?*const fn (*anyopaque, IHoverPart, HoverVerbosityAction) bool = null,
    update_verbosity: ?*const fn (*anyopaque, IHoverPart, HoverVerbosityAction, bool, HoverVerbosityListener) anyerror!void = null,
    handle_resize: ?*const fn (context: *anyopaque) void = null,
    handle_hide: ?*const fn (context: *anyopaque) void = null,
    handle_contents_changed: ?*const fn (context: *anyopaque) void = null,
    handle_scroll: ?*const fn (context: *anyopaque, scroll_top: usize, height: usize) void = null,
};

test "hover anchors: equality and adoption" {
    const range = Range.init(1, 2, 1, 5);
    const other = Range.init(1, 2, 1, 5);
    const anchor = HoverAnchor{ .range = HoverRangeAnchor.init(1, range) };
    const same = HoverAnchor{ .range = HoverRangeAnchor.init(1, other) };
    try std.testing.expect(anchor.equals(&same));
    try std.testing.expect(anchor.canAdoptVisibleHover(&same, Position.init(1, 3)));
    try std.testing.expect(!anchor.canAdoptVisibleHover(&same, Position.init(2, 3)));
}
