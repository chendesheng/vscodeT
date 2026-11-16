// Port of the portable pane bookkeeping of
// `src/vs/workbench/browser/parts/editor/editorPanes.ts`.
//
// The browser class instantiates one `EditorPane` per registered editor type,
// awaits its `setInput()` and forwards layout, visibility and size constraints
// to the active pane. The terminal workbench keeps one persistent view per tab
// instead of reusing a pane per editor type, so a tab *is* the pane here. This
// port keeps the rest of the contract: the active pane, its page position and
// the default size constraints. A terminal pane supplies `editorInput()` and
// `layoutCells(width, height)`; the group view owns the tab list and tells this
// layer which tab is active.
//
// Terminal adaptation: pane layout is synchronous (there is no async
// `setInput()` operation or cancellation token), and a layout failure is
// swallowed like upstream's `safeRun` because the grid must keep a usable
// rectangle. The default constraints are upstream's pixel values; the terminal
// grid enforces its own cell minimums.

const std = @import("std");
const editor_input = @import("../../../common/editor/editorInput.zig");
const EditorInput = editor_input.EditorInput;

/// Mirrors upstream `Dimension` for pane layout.
pub const Dimension = struct {
    width: usize,
    height: usize,
};

/// Upstream `DEFAULT_EDITOR_MIN_DIMENSIONS`.
pub const default_min_dimensions = Dimension{ .width = 220, .height = 70 };
/// Upstream `DEFAULT_EDITOR_MAX_DIMENSIONS`; the terminal has no pixel maximum.
pub const default_max_dimensions = Dimension{
    .width = std.math.maxInt(usize),
    .height = std.math.maxInt(usize),
};

/// A terminal pane: the visible editor view of one tab. The group view keeps
/// the tab list; this layer only remembers which pane is shown and the last
/// page position it was laid out with.
pub fn EditorPanes(comptime Pane: type) type {
    return struct {
        const Self = @This();

        active: ?Pane = null,
        page_position: ?Dimension = null,

        pub fn setActive(self: *Self, pane: ?Pane) void {
            self.active = pane;
            if (pane) |value| self.layoutPane(value);
        }

        pub fn activePane(self: *const Self) ?Pane {
            return self.active;
        }

        /// `doSetActiveEditorPane` clears the pane when the group hides it.
        pub fn clearActive(self: *Self) void {
            self.active = null;
        }

        /// `layout(pagePosition)`: remember the position so a pane activated
        /// later is laid out immediately, then forward it to the active pane.
        pub fn layout(self: *Self, position: Dimension) void {
            self.page_position = position;
            if (self.active) |pane| self.layoutPane(pane);
        }

        /// `closeEditor(editor)`: drop the active pane when its input closes.
        pub fn closeEditor(self: *Self, input: *EditorInput) void {
            const pane = self.active orelse return;
            if (pane.editorInput() == input) self.active = null;
        }

        /// Upstream's `minimumWidth` falls back to the default when there is no
        /// active pane. Terminal panes do not override the constraints.
        pub fn minimumWidth(self: *const Self) usize {
            _ = self;
            return default_min_dimensions.width;
        }

        pub fn minimumHeight(self: *const Self) usize {
            _ = self;
            return default_min_dimensions.height;
        }

        pub fn maximumWidth(self: *const Self) usize {
            _ = self;
            return default_max_dimensions.width;
        }

        pub fn maximumHeight(self: *const Self) usize {
            _ = self;
            return default_max_dimensions.height;
        }

        fn layoutPane(self: *Self, pane: Pane) void {
            const position = self.page_position orelse return;
            // `safeRun` in upstream: one pane must not break the grid layout.
            pane.layoutCells(position.width, position.height);
        }
    };
}

const TestInput = struct {
    base: EditorInput,

    fn create(allocator: std.mem.Allocator) !*TestInput {
        const input = try allocator.create(TestInput);
        input.* = .{ .base = EditorInput.init(allocator, "test.editorInput") };
        input.base.impl = input;
        return input;
    }

    fn deinit(self: *TestInput) void {
        self.base.deinit();
        self.base.allocator.destroy(self);
    }
};

const TestPane = struct {
    input: *EditorInput,
    layouts: usize = 0,
    width: usize = 0,
    height: usize = 0,

    pub fn editorInput(self: *TestPane) *EditorInput {
        return self.input;
    }

    pub fn layoutCells(self: *TestPane, width: usize, height: usize) void {
        self.layouts += 1;
        self.width = width;
        self.height = height;
    }
};

test "EditorPanes: activation lays out the pane at the last page position" {
    const allocator = std.testing.allocator;
    const input = try TestInput.create(allocator);
    defer input.deinit();
    var pane = TestPane{ .input = &input.base };

    var panes = EditorPanes(*TestPane){};
    panes.layout(.{ .width = 40, .height = 9 });
    try std.testing.expectEqual(@as(usize, 0), pane.layouts);

    panes.setActive(&pane);
    try std.testing.expectEqual(&pane, panes.activePane().?);
    try std.testing.expectEqual(@as(usize, 1), pane.layouts);
    try std.testing.expectEqual(@as(usize, 40), pane.width);
    try std.testing.expectEqual(@as(usize, 9), pane.height);

    panes.layout(.{ .width = 50, .height = 12 });
    try std.testing.expectEqual(@as(usize, 2), pane.layouts);
    try std.testing.expectEqual(@as(usize, 50), pane.width);
    try std.testing.expectEqual(@as(usize, 12), pane.height);
}

test "EditorPanes: closeEditor clears only the matching active pane" {
    const allocator = std.testing.allocator;
    const first = try TestInput.create(allocator);
    defer first.deinit();
    const second = try TestInput.create(allocator);
    defer second.deinit();
    var pane = TestPane{ .input = &first.base };

    var panes = EditorPanes(*TestPane){};
    panes.setActive(&pane);
    panes.closeEditor(&second.base);
    try std.testing.expectEqual(&pane, panes.activePane().?);

    panes.closeEditor(&first.base);
    try std.testing.expect(panes.activePane() == null);
}

test "EditorPanes: size constraints fall back to upstream defaults" {
    const panes = EditorPanes(*TestPane){};
    try std.testing.expectEqual(@as(usize, 220), panes.minimumWidth());
    try std.testing.expectEqual(@as(usize, 70), panes.minimumHeight());
    try std.testing.expectEqual(std.math.maxInt(usize), panes.maximumWidth());
    try std.testing.expectEqual(std.math.maxInt(usize), panes.maximumHeight());
}
