// Port of `src/vs/editor/browser/viewParts/viewCursors/viewCursor.ts`.
//
// Terminal adaptation: a cell grid has no pixel cursor geometry, so the port
// keeps the upstream configuration/plurality/visibility state and produces a
// `ViewCursorRenderData` with the view position, style and visibility. The
// terminal host owns the hardware cursor cell, the block-cursor glyph and the
// blinking animation. Grapheme-aware positioning (which needs the line content)
// and the token class name are not part of the terminal data.
const editor_options = @import("../../../common/config/editorOptions.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const Position = @import("../../../common/core/position.zig").Position;

const ViewContext = view_context.ViewContext;
const RenderingContext = rendering_context.RenderingContext;
const TextEditorCursorStyle = editor_options.TextEditorCursorStyle;

pub const CursorPlurality = enum { single, multi_primary, multi_secondary };

/// The terminal cursor data for one cursor.
pub const ViewCursorRenderData = struct {
    position: Position,
    plurality: CursorPlurality,
    style: TextEditorCursorStyle,
    visible: bool,
};

/// Port of `ViewCursor`.
pub const ViewCursor = struct {
    context: *ViewContext,

    cursor_style: TextEditorCursorStyle,
    line_cursor_width: f64,
    line_cursor_height: f64,
    typical_halfwidth_character_width: f64,

    is_visible: bool,
    position: Position,
    plurality: CursorPlurality,
    render_data: ?ViewCursorRenderData,

    pub fn init(context: *ViewContext, plurality: CursorPlurality) ViewCursor {
        var cursor = ViewCursor{
            .context = context,
            .cursor_style = .Line,
            .line_cursor_width = 0,
            .line_cursor_height = 0,
            .typical_halfwidth_character_width = 0,
            .is_visible = true,
            .position = Position.init(1, 1),
            .plurality = plurality,
            .render_data = null,
        };
        cursor.readConfig();
        return cursor;
    }

    fn readConfig(self: *ViewCursor) void {
        const options = self.context.configuration.options.?;
        const font_info = options.get(.fontInfo);
        self.cursor_style = options.get(.effectiveCursorStyle);
        self.typical_halfwidth_character_width = font_info.typicalHalfwidthCharacterWidth;
        self.line_cursor_width = @min(
            @as(f64, @floatFromInt(options.get(.cursorWidth))),
            self.typical_halfwidth_character_width,
        );
        self.line_cursor_height = @floatFromInt(options.get(.cursorHeight));
    }

    pub fn setPlurality(self: *ViewCursor, plurality: CursorPlurality) void {
        self.plurality = plurality;
    }

    pub fn show(self: *ViewCursor) void {
        self.is_visible = true;
    }

    pub fn hide(self: *ViewCursor) void {
        self.is_visible = false;
    }

    pub fn onConfigurationChanged(self: *ViewCursor) bool {
        self.readConfig();
        return true;
    }

    pub fn onCursorPositionChanged(self: *ViewCursor, position: Position) bool {
        self.position = position;
        self.render_data = null;
        return true;
    }

    pub fn prepareRender(self: *ViewCursor, context: *const RenderingContext) void {
        self.render_data = null;
        const visible_range = context.visibleRangeForPosition(self.position) orelse return;
        if (visible_range.outsideRenderedLine) {
            // Outside the viewport.
            return;
        }
        self.render_data = .{
            .position = self.position,
            .plurality = self.plurality,
            .style = self.cursor_style,
            .visible = self.is_visible,
        };
    }

    pub fn render(self: *const ViewCursor, _: *const rendering_context.RestrictedRenderingContext) ?ViewCursorRenderData {
        return self.render_data;
    }
};
