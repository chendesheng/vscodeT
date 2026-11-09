// Portable subset of
// `src/vs/editor/contrib/hover/browser/hoverTypes.ts`.
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const ModelDecoration = @import("../../../common/model.zig").ModelDecoration;

pub const HoverStartSource = enum(u8) {
    mouse = 0,
    click = 1,
    keyboard = 2,
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
    owner: *const anyopaque,
    range: Range,
    force_show_at_range: bool = false,
    is_before_content: bool = false,
    is_valid_for_hover_anchor: *const fn (context: *const anyopaque, anchor: *const HoverAnchor) bool,

    pub fn isValidForHoverAnchor(self: IHoverPart, anchor: *const HoverAnchor) bool {
        return self.is_valid_for_hover_anchor(self.owner, anchor);
    }
};

/// Portable participant contract. DOM rendering is intentionally absent.
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
};

test "hover anchors: equality and adoption" {
    const range = Range.init(1, 2, 1, 5);
    const other = Range.init(1, 2, 1, 5);
    const anchor = HoverAnchor{ .range = HoverRangeAnchor.init(1, range) };
    const same = HoverAnchor{ .range = HoverRangeAnchor.init(1, other) };
    try @import("std").testing.expect(anchor.equals(&same));
    try @import("std").testing.expect(anchor.canAdoptVisibleHover(&same, Position.init(1, 3)));
    try @import("std").testing.expect(!anchor.canAdoptVisibleHover(&same, Position.init(2, 3)));
}
