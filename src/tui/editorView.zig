//! The editor view, rendered through the standalone `ui` library.
//!
//! This replaces the hand-written `Screen`/`render.zig` path with a
//! `ui.Document`: one absolutely positioned element per view line, a gutter
//! element, inline token runs painted by `viewLineRenderer`, a status bar and a
//! hardware cursor cell. It is a deliberate terminal adaptation of
//! `src/vs/editor/browser/view/`, not a literal port: the browser view parts
//! (viewLayer, viewLines, selections, cursors) are collapsed into this file
//! until the view model is ported.
//!
//! The document is updated from the editor when `render`/`refresh` runs (after
//! a key, an edit or a viewport change). The retained line window and chrome
//! parts update in place; `Document.clear` is only used when the document is
//! created or reset. The vertical scroll position comes from the editor's
//! line-granular `ViewLayout` (upstream `viewLayout.ts`), and the render pass
//! uses the ported `ViewLines` window instead of forcing a full line pass. The
//! view also owns the terminal mouse adaptation: click/drag caret placement,
//! drag selection, click synthesis and the scrollbar-owned wheel path.
//!
//! Find, bracket, word and hover ranges are materialized as `TextModel`
//! decorations by `ModelDecorationSink` or by the view's bracket pass.
//! `TerminalViewHost` resolves them through the ported `ViewModelDecorations`,
//! and the ported `ViewLine` filters/clips them and exposes the merged inline
//! classes; this file maps those classes to terminal cell flags. Range
//! decorations that carry only a `className` (marker squiggles, the Problems
//! range highlight) come from the ported `DecorationsOverlay` instead: the host
//! maps their visible cell ranges to the same flags, which paint the diagnostic
//! squiggle underline styles. Bracket colorization classes
//! (`bracket-highlighting-N` and `unexpected-closing-bracket`) become cell
//! foregrounds here instead of the CSS color rules the browser renderer would
//! apply.
//!
//! Selections are the terminal replacement for `SelectionsOverlay` plus
//! `selections.css`: the selected cells get the theme
//! `editor.selectionBackground` (composited because cells have no alpha) and
//! their glyphs are blended toward it, since a cell cannot alpha-composite the
//! browser's selection layer over the text. High-contrast themes use the opaque
//! `editor.selectionForeground` instead. Decoration flags are applied after the
//! selection, matching the browser layer order (`SelectionsOverlay` before
//! `DecorationsOverlay`). The old ANSI reverse-video paint is gone: inverse
//! cells made an indentation guide's overlay glyph fall out of the selection
//! band and read as a black line.
//!
//! The ported `IndentGuidesOverlay` owns the guide assembly (indentation,
//! bracket pairs and the active scope); this file maps its class names to theme
//! colors and paints them as dim `│` cells over the leading whitespace.
//! Vertical bracket-pair guides and the active indentation/bracket scope use
//! brighter colors. A visible-whitespace marker keeps its cell: a `·` or a
//! one-cell tab's `→` replaces a guide that shares the cell, while a wider tab
//! keeps the guide and repeats the arrow in the next (padding) cell. Horizontal
//! guide segments are not terminal cells, so they are not painted.
//!
//! The right edge of the text area reserves two cells that double as the
//! overview ruler and the scrollbar. Marker ranges project onto text rows
//! instead of canvas pixels, so several document lines can share a row. The
//! scrollbar thumb is painted after the markers in the same cells, so it covers
//! them on the rows it occupies, matching the terminal rendering of the
//! browser's overlapping overview-ruler and slider layers.

const std = @import("std");
const ui = @import("ui");
const cellMetrics = @import("./cellMetrics.zig");

const Editor = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TerminalViewHost = @import("../vs/editor/browser/widget/codeEditor/terminalViewHost.zig").TerminalViewHost;
const tokenization = @import("../vs/editor/common/tokenizationRegistry.zig");
const time_compat = @import("../vs/base/common/timeCompat.zig");
const CursorColumns = @import("../vs/editor/common/core/cursorColumns.zig").CursorColumns;
const CursorState = @import("../vs/editor/common/cursorCommon.zig").CursorState;
const Position = @import("../vs/editor/common/core/position.zig").Position;
const Range = @import("../vs/editor/common/core/range.zig").Range;
const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
const line_renderer = @import("../vs/editor/common/viewLayout/viewLineRenderer.zig");
const editorBrowser = @import("../vs/editor/browser/editorBrowser.zig");
const editor_css = @import("../vs/editor/browser/editorCss.zig");
const decorationsOverviewRuler = @import("../vs/editor/browser/viewParts/overviewRuler/decorationsOverviewRuler.zig");
const model_module = @import("../vs/editor/common/model.zig");
const TextModel = @import("../vs/editor/common/model/textModel.zig").TextModel;
const ModelDeltaDecoration = model_module.ModelDeltaDecoration;
const ModelDecorationOptions = model_module.ModelDecorationOptions;
const OverviewRulerLane = model_module.OverviewRulerLane;
const MarkerService = @import("../vs/platform/markers/common/markerService.zig").MarkerService;
const MarkerDecorationsService = @import("../vs/editor/common/services/markerDecorationsService.zig").MarkerDecorationsService;
const markers_mod = @import("../vs/platform/markers/common/markers.zig");
const scrollbar_state = @import("../vs/base/browser/ui/scrollbar/scrollbarState.zig");
const computeIndentLevel = @import("../vs/editor/common/model/utils.zig").computeIndentLevel;
const rulers_mod = @import("../vs/editor/browser/viewParts/rulers/rulers.zig");
const scroll_decoration = @import("../vs/editor/browser/viewParts/scrollDecoration/scrollDecoration.zig");
const overlay_widgets_mod = @import("../vs/editor/browser/viewParts/overlayWidgets/overlayWidgets.zig");
const mouse_target = @import("../vs/editor/browser/controller/mouseTarget.zig");
const mouse_handler_mod = @import("../vs/editor/browser/controller/mouseHandler.zig");
const TerminalMouseHandler = mouse_handler_mod.TerminalMouseHandler;
const content_widgets_mod = @import("../vs/editor/browser/viewParts/contentWidgets/contentWidgets.zig");
const editor_scrollbar_mod = @import("../vs/editor/browser/viewParts/editorScrollbar/editorScrollbar.zig");
const margin_mod = @import("../vs/editor/browser/viewParts/margin/margin.zig");
const view_line_mod = @import("../vs/editor/browser/viewParts/viewLines/viewLine.zig");
const ViewLine = view_line_mod.ViewLine;
const view_lines_mod = @import("../vs/editor/browser/viewParts/viewLines/viewLines.zig");
const ViewLines = view_lines_mod.ViewLines;
const ViewOverlayWidgets = overlay_widgets_mod.ViewOverlayWidgets;
const ViewContentWidgets = content_widgets_mod.ViewContentWidgets;
const ContentWidgetEntry = content_widgets_mod.ContentWidgetEntry;
const view_events = @import("../vs/editor/common/viewEvents.zig");
const editor_options = @import("../vs/editor/common/config/editorOptions.zig");
const terminal_editor_config = @import("../vs/editor/browser/config/terminalEditorConfiguration.zig");
const theme_colors_mod = @import("../vs/workbench/browser/themeColors.zig");
const theme_mod = @import("../vs/platform/theme/common/theme.zig");

const gutter_color = [3]u8{ 110, 110, 110 };
const continuation_color = [3]u8{ 90, 90, 90 };
const tilde_color = [3]u8{ 70, 70, 70 };
const indent_guide_color = [3]u8{ 60, 62, 64 };
const indent_guide_active_color = [3]u8{ 96, 100, 104 };
/// Upstream `viewLines.css` paints visible whitespace with
/// `editorWhitespace.foreground`. Themes that do not define it fall back here
/// to the default foreground faded over the editor background, so whitespace
/// is one dim color everywhere instead of the surrounding token color.
const whitespace_foreground_id = "editorWhitespace.foreground";
const whitespace_fallback_alpha = 0.3;
const bracket_guide_ids = [_][]const u8{
    "editorBracketPairGuide.background1",
    "editorBracketPairGuide.background2",
    "editorBracketPairGuide.background3",
    "editorBracketPairGuide.background4",
    "editorBracketPairGuide.background5",
    "editorBracketPairGuide.background6",
};
const bracket_guide_active_ids = [_][]const u8{
    "editorBracketPairGuide.activeBackground1",
    "editorBracketPairGuide.activeBackground2",
    "editorBracketPairGuide.activeBackground3",
    "editorBracketPairGuide.activeBackground4",
    "editorBracketPairGuide.activeBackground5",
    "editorBracketPairGuide.activeBackground6",
};
const indent_guide_ids = [_][]const u8{
    "editorIndentGuide.background1",
    "editorIndentGuide.background2",
    "editorIndentGuide.background3",
    "editorIndentGuide.background4",
    "editorIndentGuide.background5",
    "editorIndentGuide.background6",
};
const indent_guide_active_ids = [_][]const u8{
    "editorIndentGuide.activeBackground1",
    "editorIndentGuide.activeBackground2",
    "editorIndentGuide.activeBackground3",
    "editorIndentGuide.activeBackground4",
    "editorIndentGuide.activeBackground5",
    "editorIndentGuide.activeBackground6",
};

/// Upstream `ColorProvider.getInlineClassNameOfLevel` colors
/// `bracket-highlighting-N` with `colorValues[N % colorValues.length]`, where
/// `colorValues` is the active theme's non-transparent
/// `editorBracketHighlight.foreground1..6` list. VS Code registers defaults
/// for those ids; the terminal's color registry does not, so the default
/// palettes below stand in for the scheme-specific registrations.
const bracket_highlight_ids = [_][]const u8{
    "editorBracketHighlight.foreground1",
    "editorBracketHighlight.foreground2",
    "editorBracketHighlight.foreground3",
    "editorBracketHighlight.foreground4",
    "editorBracketHighlight.foreground5",
    "editorBracketHighlight.foreground6",
};
const dark_bracket_highlight_colors = [_][3]u8{
    .{ 255, 215, 0 },
    .{ 218, 112, 214 },
    .{ 23, 159, 255 },
};
const light_bracket_highlight_colors = [_][3]u8{
    .{ 4, 49, 250 },
    .{ 49, 147, 49 },
    .{ 123, 56, 20 },
};
const hc_dark_bracket_highlight_colors = [_][3]u8{
    .{ 255, 215, 0 },
    .{ 218, 112, 214 },
    .{ 135, 206, 250 },
};
const dark_unexpected_bracket_color = [3]u8{ 210, 20, 21 };
const light_unexpected_bracket_color = [3]u8{ 255, 65, 65 };
const hc_dark_unexpected_bracket_color = [3]u8{ 255, 50, 50 };
const hc_light_unexpected_bracket_color = [3]u8{ 181, 32, 13 };

const find_options = makeDecorationOptions("findMatch", .Left, overview_find_color, 10);
const current_find_options = makeDecorationOptions("currentFindMatch", .Full, overview_current_find_color, 13);
const find_scope_options = makeDecorationOptions("findScope", null, null, 0);
const bracket_options = makeDecorationOptions("bracket-match", .Right, overview_bracket_color, 0);
const bracket_inline_options = makeDecorationOptions("bracket-match", null, null, 0);
const word_text_options = makeDecorationOptions("wordHighlightText", .Center, overview_word_color, 0);
const word_options = makeDecorationOptions("wordHighlight", .Center, overview_word_color, 0);
const word_strong_options = makeDecorationOptions("wordHighlightStrong", .Center, overview_word_strong_color, 0);
const hover_options = makeDecorationOptions("hoverHighlight", null, null, 0);
const range_highlight_options = makeDecorationOptions("rangeHighlight", null, null, 1);

fn makeDecorationOptions(
    comptime class_name: []const u8,
    lane: ?OverviewRulerLane,
    marker_color: ?[3]u8,
    z_index: usize,
) ModelDecorationOptions {
    var options = ModelDecorationOptions.init(class_name, .NeverGrowsWhenTypingAtEdges);
    options.className = class_name;
    options.inlineClassName = class_name;
    options.overviewRuler = if (lane != null and marker_color != null)
        .{ .position = lane.?, .color = marker_color.? }
    else
        null;
    options.zIndex = z_index;
    return options;
}

fn decorationOptions(kind: editorBrowser.DecorationKind, show_in_overview: bool) *const ModelDecorationOptions {
    return switch (kind) {
        .find_match => &find_options,
        .current_find_match => &current_find_options,
        .find_scope => &find_scope_options,
        .bracket_match => if (show_in_overview) &bracket_options else &bracket_inline_options,
        .hover_highlight => &hover_options,
        .word_highlight_text => &word_text_options,
        .word_highlight => &word_options,
        .word_highlight_strong => &word_strong_options,
        .search_range_highlight => &range_highlight_options,
        .marker_selection_highlight => &range_highlight_options,
    };
}

fn overviewRulerLaneFromModel(lane: OverviewRulerLane) decorationsOverviewRuler.Lane {
    return switch (lane) {
        .Left => .left,
        .Center => .center,
        .Right => .right,
        .Full => .full,
    };
}
const current_line_background = [3]u8{ 32, 32, 36 };
const secondary_cursor_background = [3]u8{ 110, 90, 30 };

/// Terminal contribution callback for `View.applyEditorSettings`.
pub const ConfigurationListener = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque) void,
};

/// A cell position, 0-based, ready for `tui.moveCursor` after adding one.
pub const Cell = struct {
    row: usize,
    col: usize,
};

const GuideSpec = struct {
    row: usize,
    col: usize,
    color: [3]u8,
};

const DecorationOwner = struct {
    const find: usize = 1;
    const bracket: usize = 2;
    const word: usize = 3;
    const hover: usize = 4;
    const search: usize = 5;
    const marker_selection: usize = 6;
    /// Vim/Helix incremental-search highlights. Separate from the Search view
    /// result range above, so the two never clear each other.
    const incremental_search: usize = 7;
};

const CellFlag = struct {
    const normal: u32 = 0;
    const selected: u32 = 1 << 0;
    const secondary_cursor: u32 = 1 << 1;
    const find_match: u32 = 1 << 2;
    const current_find_match: u32 = 1 << 3;
    const find_scope: u32 = 1 << 4;
    const bracket_match: u32 = 1 << 5;
    const hover_highlight: u32 = 1 << 6;
    const word_highlight_text: u32 = 1 << 7;
    const word_highlight: u32 = 1 << 8;
    const word_highlight_strong: u32 = 1 << 9;
    const snippet_placeholder: u32 = 1 << 10;
    const finish_snippet_placeholder: u32 = 1 << 11;
    const value_set_replacement: u32 = 1 << 12;
    const search_range_highlight: u32 = 1 << 13;
    const diagnostic_error: u32 = 1 << 14;
    const diagnostic_warning: u32 = 1 << 15;
    const diagnostic_info: u32 = 1 << 16;
    const diagnostic_hint: u32 = 1 << 17;
    /// `.squiggly-unnecessary`: the main dashed/dim hint decoration.
    const diagnostic_unnecessary: u32 = 1 << 18;
    /// `.squiggly-inline-deprecated`: the inline line-through tag.
    const diagnostic_deprecated: u32 = 1 << 19;
    const char_insert: u32 = 1 << 20;
    const char_delete: u32 = 1 << 21;
    /// `.squiggly-inline-unnecessary`: the inline opacity/dim tag.
    const diagnostic_inline_unnecessary: u32 = 1 << 22;
};

const find_match_background = [3]u8{ 80, 70, 20 };
const current_find_match_background = [3]u8{ 200, 120, 0 };
const current_find_match_foreground = [3]u8{ 0, 0, 0 };
const find_scope_background = [3]u8{ 40, 50, 70 };
const bracket_match_background = [3]u8{ 45, 80, 55 };
const bracket_match_foreground = [3]u8{ 235, 255, 235 };
/// Upstream's `editor.hoverHighlightBackground` (#264f7840) is translucent.
/// Cells have no alpha, so this is the dark-theme color composited over the
/// editor background, keeping the text readable.
const hover_highlight_background = [3]u8{ 32, 42, 52 };
/// `editor.wordHighlightBackground` / `wordHighlightTextBackground`
/// (#575757B8) and `wordHighlightStrongBackground` (#004972B8), composited
/// over the dark editor background because cells have no alpha.
const word_highlight_background = [3]u8{ 71, 71, 71 };
const word_highlight_strong_background = [3]u8{ 8, 61, 91 };
/// Snippet placeholder decorations are CSS backgrounds upstream. Cells have
/// no alpha, so these are composited over the dark editor background.
const snippet_placeholder_background = [3]u8{ 52, 58, 68 };
const finish_snippet_placeholder_background = [3]u8{ 66, 56, 42 };
const search_range_highlight_background = [3]u8{ 48, 54, 66 };
const diagnostic_error_color = [3]u8{ 241, 76, 76 };
const diagnostic_warning_color = [3]u8{ 204, 167, 0 };
const diagnostic_info_color = [3]u8{ 55, 148, 255 };
const diagnostic_hint_color = [3]u8{ 138, 138, 138 };

/// Fallbacks for the selection paint. Upstream registers
/// `editor.selectionBackground` (dark `#264F78`, light `#ADD6FF`, hcDark
/// `#f3f518`, hcLight `#0F4A85`) and `editor.selectionForeground` (hcDark
/// `#000000`, hcLight `#FFFFFF`) as color-registry defaults; those defaults are
/// not ported, so the view keeps its own literals, like the other paint colors.
/// The default themes do not define the selection ids in their JSON.
const selection_background_dark = [3]u8{ 0x26, 0x4F, 0x78 };
const selection_background_light = [3]u8{ 0xAD, 0xD6, 0xFF };
const selection_background_hc_dark = [3]u8{ 0xF3, 0xF5, 0x18 };
const selection_background_hc_light = [3]u8{ 0x0F, 0x4A, 0x85 };
const selection_foreground_hc_dark = [3]u8{ 0x00, 0x00, 0x00 };
const selection_foreground_hc_light = [3]u8{ 0xFF, 0xFF, 0xFF };
/// Plain editor text without a token color is the terminal default; the theme's
/// `editor.foreground` replaces it only where the selection paint needs an
/// explicit RGB (the fallback matches `ThemeColors.init`).
const default_text_color = [3]u8{ 204, 204, 204 };
/// Fraction of its own color the covered glyph keeps. A terminal cell cannot
/// alpha-composite the browser's selection layer over the text, so the glyph is
/// blended toward the selection background instead.
const selection_text_alpha: f32 = 0.7;

/// Diff editor backgrounds. Upstream `diffEditor.insertedLineBackground`
/// (rgba(155,185,85,.2)), `removedLineBackground` (rgba(255,0,0,.2)),
/// `insertedTextBackground` (#9ccc2c33) and `removedTextBackground` (#ff000033)
/// are translucent; cells have no alpha, so these are composited over the dark
/// editor background.
const diff_insert_line_background = [3]u8{ 55, 61, 41 };
const diff_delete_line_background = [3]u8{ 75, 24, 24 };
const diff_filler_background = [3]u8{ 40, 42, 44 };
const diff_insert_char_background = [3]u8{ 74, 84, 45 };
const diff_delete_char_background = [3]u8{ 92, 30, 30 };

/// Overview-ruler marker colors. Cells have no alpha, so the translucent
/// upstream theme colors are composited over the dark editor background.
/// Find/current-find follow `editorOverviewRuler.findMatchForeground`; the
/// current match keeps the stronger inline find color so it stands out.
const overview_find_color = [3]u8{ 96, 66, 22 };
const overview_current_find_color = [3]u8{ 150, 90, 0 };
const overview_bracket_color = [3]u8{ 92, 92, 92 };
const overview_word_color = [3]u8{ 78, 78, 78 };
const overview_word_strong_color = [3]u8{ 96, 80, 96 };
const overview_cursor_color = [3]u8{ 92, 93, 91 };
const overview_secondary_cursor_color = [3]u8{ 86, 70, 26 };
/// The thumb is intentionally a little brighter than the markers so it remains
/// distinguishable while the marker cells stay subdued.
const scrollbar_thumb_color = [3]u8{ 108, 108, 108 };

/// Key for the view's shared paint styles: token color + attributes, the
/// inline-decoration class list and the terminal cell flags. This is the
/// terminal equivalent of the browser's CSS class list on a text span.
const PaintStyleKey = struct {
    foreground: u9,
    attrs: u8,
    flags: u32,
    is_whitespace: bool,
    class: []const u8,

    const Context = struct {
        pub fn hash(_: Context, key: PaintStyleKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&key.foreground));
            hasher.update(std.mem.asBytes(&key.attrs));
            hasher.update(std.mem.asBytes(&key.flags));
            hasher.update(std.mem.asBytes(&key.is_whitespace));
            hasher.update(key.class);
            return hasher.final();
        }

        pub fn eql(_: Context, a: PaintStyleKey, b: PaintStyleKey) bool {
            return a.foreground == b.foreground and
                a.attrs == b.attrs and
                a.flags == b.flags and
                a.is_whitespace == b.is_whitespace and
                std.mem.eql(u8, a.class, b.class);
        }
    };
};

const default_paint_style: ui.style.PaintStyle = .{};

pub const PerfCounters = struct {
    full_box_solves: usize = 0,
    /// Incremental sync passes after the first full solve.
    incremental_syncs: usize = 0,
    /// Incremental passes where a retained chrome part issued explicit box
    /// operations. The whole-chrome subtree rebuild no longer runs per frame.
    chrome_rebuilds: usize = 0,
    chrome_subtrees_added: usize = 0,
    chrome_subtrees_rebuilt: usize = 0,
    chrome_subtrees_translated: usize = 0,
    chrome_subtrees_removed: usize = 0,
    line_added: usize = 0,
    line_rebuilt: usize = 0,
    line_translated: usize = 0,
};

/// A one-line content-widget tooltip for the glyph-margin hover message.
const GlyphTooltip = struct {
    visible: bool = false,
    line: usize = 1,
    text_buf: [192]u8 = undefined,
    text_len: usize = 0,
    node: ?*ui.Node = null,

    fn text(self: *const GlyphTooltip) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    fn setText(self: *GlyphTooltip, value: []const u8) void {
        self.text_len = @min(value.len, self.text_buf.len);
        @memcpy(self.text_buf[0..self.text_len], value[0..self.text_len]);
        self.visible = self.text_len > 0;
    }

    fn clear(self: *GlyphTooltip) void {
        self.visible = false;
        self.text_len = 0;
    }

    fn getPosition(context: *anyopaque) ?editorBrowser.IContentWidgetPosition {
        const self: *GlyphTooltip = @ptrCast(@alignCast(context));
        if (!self.visible) return null;
        return .{
            .position = Position.init(self.line, 1),
            .preference = .below,
        };
    }

    fn width(context: *anyopaque, cols: usize) usize {
        const self: *GlyphTooltip = @ptrCast(@alignCast(context));
        return @min(self.text_len + 2, cols);
    }

    fn height(_: *anyopaque) usize {
        return 1;
    }

    fn build(context: *anyopaque, doc: *ui.Document) anyerror!*ui.Node {
        const self: *GlyphTooltip = @ptrCast(@alignCast(context));
        const node = try doc.createElement(.div);
        node.setStyle(.{
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .background = .{ .r = 50, .g = 50, .b = 55 },
            .color = .{ .r = 230, .g = 230, .b = 230 },
            .white_space = .pre,
            .overflow = .hidden,
        });
        const label = try doc.createText(self.text());
        _ = try node.appendChild(label);
        self.node = node;
        return node;
    }

    fn focusNode(_: *anyopaque) ?*ui.Node {
        return null;
    }

    fn isFocused(_: *anyopaque) bool {
        return false;
    }

    fn id(_: *anyopaque) []const u8 {
        return "glyph-tooltip";
    }

    fn interface(self: *GlyphTooltip) editorBrowser.IContentWidget {
        return .{
            .context = self,
            .get_id = id,
            .get_position = getPosition,
            .width = width,
            .height = height,
            .build = build,
            .focus_node = focusNode,
            .is_focused = isFocused,
        };
    }
};

pub const View = struct {
    allocator: std.mem.Allocator,
    editor: *Editor,
    surface: ui.Surface,
    /// Overlay widgets anchored to an editor corner, painted above the lines
    /// and the status row.
    /// Content widgets anchored to model positions, painted above the lines
    /// and below the overlays (the hover widget is one).
    /// Content widget containers for the current frame, used to hit-test and
    /// to keep pointer events out of the text.
    /// Overlay widget rectangles for the current frame; pointer events on an
    /// overlay must not reach the editor's hover logic.
    /// Primary-cursor row relative to the viewport, when it is on screen.
    cursor_row: ?usize = null,
    /// Absolute terminal column of the primary caret.
    cursor_col: usize = 0,
    /// Width of the rightmost cells reserved for the combined overview ruler
    /// and scrollbar. The editor wraps around the same width.
    scrollbar_width: usize = 0,
    /// Terminal find view zone: blank rows reserved above line 1. The find
    /// widget paints over these rows; text and hit testing start below them.
    top_inset_rows: usize = 0,
    mouse_handler: TerminalMouseHandler = .{},
    /// Workbench status-bar text supplied through the ported
    /// `StatusbarModel`. Empty slices fall back to the editor's own status
    /// string so standalone editor view tests keep their old contract.
    status_left: [512]u8 = undefined,
    status_left_len: usize = 0,
    status_right: [256]u8 = undefined,
    status_right_len: usize = 0,
    /// Whether this view paints the editor's fallback status row. The
    /// multi-group workbench disables it in favour of its status-bar part.
    status_bar_visible: bool = true,
    glyph_tooltip: GlyphTooltip = .{},
    /// Set when a widget/status/layout change made the current document
    /// stale. The next paint/render flushes it, so a burst of registrations
    /// costs one render instead of one per call.
    needs_render: bool = true,
    /// The retained document roots (viewport, windowed content, chrome). They
    /// are rebuilt only on resize/theme/capacity resets; ordinary refreshes
    /// update the existing tree in place.
    document_ready: bool = false,
    root_node: ?*ui.Node = null,
    content_root: ?*ui.Node = null,
    /// Horizontal viewport for the rendered line content. The UI library owns
    /// the clip/translate nodes; the editor mirrors ViewLayout's scroll offset
    /// into it each frame. Vertical scrolling stays the view-model line window.
    line_scroll: ui.ScrollView = undefined,
    line_scroll_ready: bool = false,
    line_scroll_applied: usize = 0,
    line_scroll_width: usize = 0,
    line_scroll_text_width: usize = 0,
    line_scroll_text_height: usize = 0,
    /// Content layer for ported block decorations. It sits before the line
    /// nodes in `content_root`, so block backgrounds/borders paint under text.
    block_root: ?*ui.Node = null,
    block_nodes: std.array_list.Managed(*ui.Node),
    chrome_root: ?*ui.Node = null,
    /// Stable containers for the retained chrome parts, in paint order. Each
    /// part updates its own container; a refresh never clears the chrome root.
    gutter_root: ?*ui.Node = null,
    scrollbar_root: ?*ui.Node = null,
    overlay_widgets_root: ?*ui.Node = null,
    content_widgets_root: ?*ui.Node = null,
    status_root: ?*ui.Node = null,
    /// Retained editor status row nodes; their text borrows the stable
    /// `status_left`/`status_right` buffers and is only rewritten when the
    /// status signature changes.
    status_bar: ?*ui.Node = null,
    status_left_text: ?*ui.Node = null,
    status_right_box: ?*ui.Node = null,
    status_right_text: ?*ui.Node = null,
    status_signature: u64 = 0,
    status_active: bool = false,
    status_row: usize = 0,
    /// The box tree has to be rebuilt from scratch (first frame, resize,
    /// theme rescan or the incremental capacity bound).
    needs_full_box_rebuild: bool = true,
    /// Retained-path work counters; the benchmark prints these so a chrome
    /// retainer can be measured against the line path instead of guessed.
    perf: PerfCounters = .{},
    /// Diagnostic counter for tests/benchmarks: immediate render passes.
    render_count: usize = 0,
    last_bracket_generation: ?usize = null,
    /// Contribution callbacks notified after `editor.*` view settings change.
    configuration_listeners: std.array_list.Managed(ConfigurationListener),
    /// Bridges the terminal editor to the ported `ViewLines` stack. The
    /// renderer below consumes its rendered line records.
    terminal_view_host: *TerminalViewHost,
    /// Active color-theme palette; null keeps the standalone fallback colors.
    theme_colors: ?*const theme_colors_mod.ThemeColors = null,
    /// Interned paint styles for visible text runs, keyed by the CSS-class
    /// analogue. Cleared when the theme changes.
    paint_styles: std.HashMapUnmanaged(PaintStyleKey, *const ui.style.PaintStyle, PaintStyleKey.Context, 80) = .empty,
    /// Non-transparent bracket-highlight colors, in theme order, cycled by
    /// `bracket-highlighting-N`. Refreshed when the palette changes.
    bracket_highlight_colors: [6]ui.Color = undefined,
    bracket_highlight_color_count: usize = 0,
    /// The same pool before transparent entries are dropped. Guide colors are
    /// derived from the color at the *same* level, like upstream, not from the
    /// cycled colorization pool.
    bracket_highlight_by_level: [6]?ui.Color = undefined,
    bracket_guide_colors: [6]GuideColors = undefined,
    bracket_guide_color_count: usize = 0,
    indent_guide_colors: [6]GuideColors = undefined,
    indent_guide_color_count: usize = 0,
    unexpected_bracket_color: ui.Color = .{ .r = 210, .g = 20, .b = 21 },

    pub fn init(allocator: std.mem.Allocator, editor: *Editor) !*View {
        const self = try allocator.create(View);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .surface = undefined,
            .block_nodes = std.array_list.Managed(*ui.Node).init(allocator),
            .configuration_listeners = std.array_list.Managed(ConfigurationListener).init(allocator),
            .terminal_view_host = undefined,
        };
        self.refreshBracketHighlightColors();
        self.terminal_view_host = try TerminalViewHost.init(allocator, editor);
        errdefer self.terminal_view_host.deinit();
        try self.terminal_view_host.viewRef().addContentWidget(self.glyph_tooltip.interface());

        editor.setScrollbarWidth(overviewRulerWidth(editor));
        self.scrollbar_width = editor.scrollbar_width;
        self.surface = try ui.Surface.init(allocator, .{
            .cols = editor.screen_width,
            .rows = editor.screen_height,
            .tab_size = editor.tabSize(),
            .measure_width = cellMetrics.measureCodepoint,
        });
        errdefer self.surface.deinit();
        try editor_css.register(self.surface.document());
        // The first paint/render flushes the initial render. Callers that only
        // construct a view (the workbench open path) can batch widget and
        // layout changes before paying for it.
        return self;
    }

    pub fn deinit(self: *View) void {
        self.block_nodes.deinit();
        self.clearPaintStyles();
        self.paint_styles.deinit(self.allocator);
        self.configuration_listeners.deinit();
        _ = self.terminal_view_host.viewRef().removeContentWidget("glyph-tooltip");
        self.terminal_view_host.deinit();
        self.surface.deinit();
        self.allocator.destroy(self);
    }

    /// Registers a contribution callback invoked after view settings change.
    pub fn addConfigurationListener(self: *View, listener: ConfigurationListener) !void {
        try self.configuration_listeners.append(listener);
    }

    pub fn removeConfigurationListener(self: *View, listener: ConfigurationListener) void {
        for (self.configuration_listeners.items, 0..) |existing, index| {
            if (existing.context == listener.context and existing.notify == listener.notify) {
                _ = self.configuration_listeners.orderedRemove(index);
                return;
            }
        }
    }

    /// Marks the current document stale. The next paint/render flushes it.
    pub fn invalidate(self: *View) void {
        self.needs_render = true;
    }

    pub fn setTopInset(self: *View, rows: usize) void {
        const max_rows = self.surface.document().rows -| 1;
        const clamped = @min(rows, max_rows);
        if (clamped == self.top_inset_rows) return;
        self.top_inset_rows = clamped;
        self.applyTopInset();
        self.needs_full_box_rebuild = true;
        self.invalidate();
    }

    fn applyTopInset(self: *View) void {
        const doc = self.surface.document();
        const rows = doc.rows;
        const inset = self.top_inset_rows;
        const height = @max(rows -| inset, 1);
        const inset_f: f64 = @floatFromInt(inset);
        const height_f: f64 = @floatFromInt(height);
        const roots = [_]?*ui.Node{
            self.block_root,
            self.content_root,
            self.gutter_root,
            self.scrollbar_root,
            self.content_widgets_root,
        };
        for (roots) |maybe_node| {
            const node = maybe_node orelse continue;
            node.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = inset_f },
                .width = .{ .percent = 100 },
                .height = .{ .cells = height_f },
            });
        }
    }

    pub fn needsRender(self: *const View) bool {
        return self.needs_render;
    }

    /// Diagnostic counter for tests/benchmarks: immediate render passes.
    pub fn renderCount(self: *const View) usize {
        return self.render_count;
    }

    pub fn perfCounters(self: *const View) PerfCounters {
        return self.perf;
    }

    fn ensureRendered(self: *View) !void {
        if (!self.needs_render) return;
        try self.render(true, false);
    }

    /// Registers an overlay widget. The caller owns the widget struct and must
    /// keep its context alive until it is removed or the view is destroyed.
    pub fn addOverlayWidget(self: *View, widget: editorBrowser.IOverlayWidget) !void {
        try self.terminal_view_host.viewRef().addOverlayWidget(widget);
        self.invalidate();
    }

    /// Registers a content widget anchored to a model position.
    pub fn addContentWidget(self: *View, widget: editorBrowser.IContentWidget) !void {
        try self.terminal_view_host.viewRef().addContentWidget(widget);
        self.invalidate();
    }

    /// Enables or disables the view's own status row. Disabling it gives the
    /// surface's last row back to editor text.
    /// Changes the cell columns reserved for the overview ruler/scrollbar.
    /// The read-only preview uses zero; the multi-pane workbench keeps the
    /// default computed width.
    pub fn setScrollbarWidth(self: *View, width: usize) !void {
        if (self.scrollbar_width == width) return;
        self.scrollbar_width = width;
        self.editor.setScrollbarWidth(width);
        self.document_ready = false;
        try self.refresh();
    }

    pub fn setStatusBarVisible(self: *View, visible: bool) !void {
        if (self.status_bar_visible == visible) return;
        self.status_bar_visible = visible;
        self.editor.setStatusRow(visible);
        self.document_ready = false;
        self.invalidate();
    }

    /// Supplies the standalone editor view's fallback status text. Workbench
    /// tabs disable this row and use the workbench status bar instead.
    pub fn setStatusText(self: *View, left: []const u8, right: []const u8) void {
        const left_len = @min(left.len, self.status_left.len);
        @memcpy(self.status_left[0..left_len], left[0..left_len]);
        self.status_left_len = left_len;
        const right_len = @min(right.len, self.status_right.len);
        @memcpy(self.status_right[0..right_len], right[0..right_len]);
        self.status_right_len = right_len;
    }

    /// Replaces the find contribution's model decorations.
    pub fn setDecorations(self: *View, decorations: []const editorBrowser.Decoration) !void {
        try self.replaceModelDecorations(DecorationOwner.find, decorations);
    }

    /// Sets (or clears, with an empty slice) the hover highlight range.
    pub fn setHoverDecorations(self: *View, decorations: []const editorBrowser.Decoration) !void {
        try self.replaceModelDecorations(DecorationOwner.hover, decorations);
    }

    /// Sets (or clears, with an empty slice) the word-occurrence highlights.
    pub fn setWordHighlights(self: *View, decorations: []const editorBrowser.Decoration) !void {
        try self.replaceModelDecorations(DecorationOwner.word, decorations);
    }

    /// Sets the range highlighted by the Search view.
    pub fn setSearchHighlights(self: *View, decorations: []const editorBrowser.Decoration) !void {
        try self.replaceModelDecorations(DecorationOwner.search, decorations);
    }

    /// Sets (or clears) the Problems marker-selection range. This is the
    /// terminal `rangeHighlight` decoration and uses its own owner so Search
    /// highlights are not cleared by Problems.
    pub fn setMarkerSelectionHighlights(self: *View, decorations: []const editorBrowser.Decoration) !void {
        try self.replaceModelDecorations(DecorationOwner.marker_selection, decorations);
    }

    pub fn clearDecorations(self: *View) !void {
        try self.setDecorations(&.{});
    }

    fn replaceModelDecorations(
        self: *View,
        owner: usize,
        decorations: []const editorBrowser.Decoration,
    ) !void {
        try replaceModelDecorationsFor(self.editor.model, owner, decorations);
    }

    /// A contribution-facing sink that writes model decorations directly,
    /// without going through the view. The view reads the same model
    /// decorations back for painting and the overview ruler.
    pub const ModelDecorationSink = struct {
        model: *TextModel,
        owner: usize,

        /// Sink for the vim/helix incremental-search highlights. They reuse
        /// the find decoration kinds, so the view paints them with the same
        /// colors as Ctrl+F.
        pub fn incrementalSearch(model: *TextModel) ModelDecorationSink {
            return .{ .model = model, .owner = DecorationOwner.incremental_search };
        }

        pub fn context(self: *ModelDecorationSink) *anyopaque {
            return self;
        }

        pub fn set(sink_context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void {
            const self: *ModelDecorationSink = @ptrCast(@alignCast(sink_context orelse return));
            replaceModelDecorationsFor(self.model, self.owner, decorations) catch {};
        }
    };

    pub fn replaceModelDecorationsFor(
        model: *TextModel,
        owner: usize,
        decorations: []const editorBrowser.Decoration,
    ) !void {
        const allocator = model.getAllocator();
        try model.removeAllDecorationsWithOwnerId(owner);
        if (decorations.len == 0) return;

        const deltas = try allocator.alloc(ModelDeltaDecoration, decorations.len);
        defer allocator.free(deltas);
        for (decorations, 0..) |decoration, index| {
            deltas[index] = .{
                .range = decoration.range,
                .options = @constCast(decorationOptions(decoration.kind, decoration.show_in_overview_ruler)),
            };
        }

        const ids = try model.deltaDecorations(&.{}, deltas, owner);
        defer allocator.free(ids);
    }

    pub fn removeOverlayWidget(self: *View, id: []const u8) !void {
        if (self.terminal_view_host.viewRef().removeOverlayWidget(id)) {
            self.invalidate();
        }
    }

    pub fn removeContentWidget(self: *View, id: []const u8) !void {
        if (self.terminal_view_host.viewRef().removeContentWidget(id)) {
            self.invalidate();
        }
    }

    /// Sends the event through the widget document when a widget owns focus.
    /// Returns true when a listener consumed it, so the editor must not also
    /// handle the key.
    pub fn dispatchKey(self: *View, event: *ui.KeyEvent) bool {
        self.ensureRendered() catch return false;
        const doc = self.surface.document();
        if (doc.focusedElement() == null) return false;
        doc.dispatchEvent(event);
        return event.default_prevented or event.propagation_stopped;
    }

    /// Hit-tests and dispatches a mouse event, then applies the editor's own
    /// default actions: a press places the caret, a drag selects, and the wheel
    /// scrolls the viewport. Returns true when the caret or selection changed.
    pub fn dispatchMouse(self: *View, event: *ui.MouseEvent) !bool {
        try self.ensureRendered();
        const doc = self.surface.document();
        const target = (try self.surface.elementFromPoint(event.x, event.y)) orelse
            (doc.root orelse return false);
        ui.event.dispatchMouse(doc, target, event);
        // Upstream the scrollable element, not the pointer handler, owns the
        // wheel. Route it through the ported scrollbar part so sensitivity,
        // fast scroll and clamping match the browser path.
        if (event.kind == .wheel) {
            // The status row is outside the editor's scrollable element.
            if (event.y >= self.editor.textHeight()) return false;
            if (!event.default_prevented and event.delta_y != 0) {
                _ = self.terminal_view_host.viewRef().scrollbarPart().delegateScrollFromMouseWheelEvent(
                    self.editor,
                    event.delta_y,
                    event.mods,
                    self.terminal_view_host.options.get(.mouseWheelScrollSensitivity),
                    self.terminal_view_host.options.get(.fastScrollSensitivity),
                );
            }
            return false;
        }
        return self.mouse_handler.dispatch(.{
            .context = self,
            .element_from_point = mouseElementAt,
            .root_node = mouseRootNode,
            .is_scrollbar_hit = mouseIsScrollbarHit,
            .begin_scrollbar_drag = mouseBeginScrollbarDrag,
            .end_scrollbar_drag = mouseEndScrollbarDrag,
            .scrollbar_dragging = mouseScrollbarDragging,
            .drag_scrollbar = mouseDragScrollbar,
            .toggle_fold = mouseToggleFold,
            .line_for_node = mouseLineForNode,
            .position_at_cell = mousePositionAtCell,
            .set_cursor = mouseSetCursor,
            .selection_start = mouseSelectionStart,
            .select_from = mouseSelectFrom,
            .update_drag_selection = mouseUpdateDragSelection,
            .dispatch_click = mouseDispatchClick,
        }, event, target);
    }

    fn mouseIsScrollbarHit(context: *anyopaque, x: usize, y: usize) bool {
        const self: *View = @ptrCast(@alignCast(context));
        return self.isScrollbarCell(x) and
            y < self.editor.textHeight() and
            !self.pointInWidget(x, y);
    }

    fn mouseBeginScrollbarDrag(context: *anyopaque, x: usize, y: usize) void {
        const self: *View = @ptrCast(@alignCast(context));
        self.terminal_view_host.viewRef().scrollbarPart().beginDrag(
            self.editor,
            x,
            y,
            self.surface.document().cols,
            self.scrollbar_width,
            self.editor.textHeight(),
        );
    }

    fn mouseEndScrollbarDrag(context: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(context));
        self.terminal_view_host.viewRef().scrollbarPart().endDrag();
    }

    fn mouseScrollbarDragging(context: *anyopaque) bool {
        const self: *View = @ptrCast(@alignCast(context));
        return self.terminal_view_host.viewRef().scrollbarPart().isDragging();
    }

    fn mouseDragScrollbar(context: *anyopaque, y: usize) void {
        const self: *View = @ptrCast(@alignCast(context));
        _ = self.terminal_view_host.viewRef().scrollbarPart().dragTo(
            self.editor,
            y,
            self.editor.textHeight(),
        );
    }

    fn mouseToggleFold(context: *anyopaque, x: usize, y: usize) !bool {
        const self: *View = @ptrCast(@alignCast(context));
        return self.toggleFoldControl(x, y);
    }

    fn mouseLineForNode(context: *anyopaque, node: *ui.Node) ?usize {
        const self: *View = @ptrCast(@alignCast(context));
        return self.lineViewLineAt(node);
    }

    fn mousePositionAtCell(context: *anyopaque, view_line: usize, x: usize) !Position {
        const self: *View = @ptrCast(@alignCast(context));
        return self.positionAtCell(view_line, x);
    }

    fn mouseSetCursor(context: *anyopaque, position: Position) !void {
        const self: *View = @ptrCast(@alignCast(context));
        try self.editor.setCursorPosition(position);
    }

    fn mouseSelectionStart(context: *anyopaque) Position {
        const self: *View = @ptrCast(@alignCast(context));
        return self.editor.modelSelection().getSelectionStart();
    }

    fn mouseSelectFrom(context: *anyopaque, anchor: Position, position: Position) !void {
        const self: *View = @ptrCast(@alignCast(context));
        try self.selectFrom(anchor, position);
    }

    fn mouseUpdateDragSelection(context: *anyopaque, anchor: Position, position: Position) !void {
        const self: *View = @ptrCast(@alignCast(context));
        try self.editor.updateDragSelection(anchor, position);
    }

    fn mouseDispatchClick(
        context: *anyopaque,
        press_x: usize,
        press_y: usize,
        x: usize,
        y: usize,
        mods: ui.Modifiers,
    ) void {
        const self: *View = @ptrCast(@alignCast(context));
        const doc = self.surface.document();
        const target = self.surface.elementFromPoint(x, y) catch null;
        const target_node = target orelse doc.root orelse return;
        const press_target = (self.surface.elementFromPoint(press_x, press_y) catch null) orelse
            (doc.root orelse target_node);
        const click_target = ui.event.commonInclusiveAncestor(press_target, target_node) orelse press_target;
        var click = ui.MouseEvent{
            .kind = .click,
            .x = x,
            .y = y,
            .button = .left,
            .mods = mods,
        };
        ui.event.dispatchMouse(doc, click_target, &click);
    }

    fn isScrollbarCell(self: *View, x: usize) bool {
        if (self.scrollbar_width == 0) return false;
        const cols = self.surface.document().cols;
        return x >= cols -| self.scrollbar_width;
    }

    fn pointInWidget(self: *const View, x: usize, y: usize) bool {
        for (self.terminal_view_host.viewRef().contentWidgets().entries.items) |entry| {
            if (y >= self.top_inset_rows and entry.contains(x, y - self.top_inset_rows)) return true;
        }
        for (self.terminal_view_host.viewRef().overlayWidgets().entries.items) |entry| {
            if (entry.contains(x, y)) return true;
        }
        return false;
    }

    fn lineViewLineAt(self: *const View, target: *ui.Node) ?usize {
        var node: ?*ui.Node = target;
        while (node) |current| : (node = current.parent) {
            if (self.terminal_view_host.viewLineNumberForNode(current)) |view_line| return view_line;
        }
        return null;
    }

    /// The mouse target for a cell, classified by the ported
    /// `MouseTargetFactory` subset.
    pub fn mouseTargetAt(self: *View, x: usize, y: usize) !editorBrowser.MouseTarget {
        try self.ensureRendered();
        return mouse_target.createMouseTarget(.{
            .context = self,
            .element_at = mouseElementAt,
            .content_widget_contains = mouseContentWidgetContains,
            .overlay_widget_contains = mouseOverlayWidgetContains,
            .geometry = mouseGeometry,
            .line_text_width = mouseLineTextWidth,
            .position_at_view_point = mousePositionAtViewPoint,
        }, x, y);
    }

    fn mouseElementAt(context: *anyopaque, x: usize, y: usize) ?*ui.Node {
        const self: *View = @ptrCast(@alignCast(context));
        return self.surface.elementFromPoint(x, y) catch null;
    }

    fn mouseRootNode(context: *anyopaque) ?*ui.Node {
        const self: *View = @ptrCast(@alignCast(context));
        return self.surface.document().root;
    }

    fn mouseContentWidgetContains(context: *anyopaque, x: usize, y: usize) bool {
        const self: *View = @ptrCast(@alignCast(context));
        for (self.terminal_view_host.viewRef().contentWidgets().entries.items) |entry| {
            if (y >= self.top_inset_rows and entry.contains(x, y - self.top_inset_rows)) return true;
        }
        return false;
    }

    fn mouseOverlayWidgetContains(context: *anyopaque, x: usize, y: usize) bool {
        const self: *View = @ptrCast(@alignCast(context));
        for (self.terminal_view_host.viewRef().overlayWidgets().entries.items) |entry| {
            if (entry.contains(x, y)) return true;
        }
        return false;
    }

    fn mouseGeometry(context: *anyopaque) mouse_target.Geometry {
        const self: *View = @ptrCast(@alignCast(context));
        return .{
            .cols = self.surface.document().cols,
            .text_height = self.editor.textHeight(),
            .gutter_width = self.editor.gutterWidth(),
            .glyph_width = self.editor.gutterGlyphWidth(),
            .top_view_line = self.editor.topViewLine(),
            .view_line_count = self.editor.viewLineCount(),
            .scrollbar_width = self.scrollbar_width,
            .top_inset = self.top_inset_rows,
            .scroll_left = self.editor.scrollLeft(),
        };
    }

    fn mouseLineTextWidth(context: *anyopaque, view_line: usize) ?usize {
        const self: *View = @ptrCast(@alignCast(context));
        return self.terminal_view_host.getLineWidth(view_line);
    }

    fn mousePositionAtViewPoint(context: *anyopaque, view_line: usize, column: usize) !Position {
        const self: *View = @ptrCast(@alignCast(context));
        return self.editor.positionAtViewPoint(view_line, column);
    }

    /// The last gutter cell is the fold-control column. It only toggles when
    /// the view line is the first output line of a model line with a region.
    fn foldControlAt(self: *const View, x: usize, y: usize) ?usize {
        if (!self.editor.hasFoldControl() or x != self.editor.foldCellColumn()) return null;
        if (y >= self.editor.textHeight()) return null;
        const view_line = self.editor.topViewLine() + y;
        if (view_line > self.editor.viewLineCount()) return null;
        if (self.editor.outputLineIndex(view_line) != 0) return null;
        return view_line;
    }

    fn toggleFoldControl(self: *View, x: usize, y: usize) !bool {
        const view_line = self.foldControlAt(x, y) orelse return false;
        const changed = try self.editor.toggleFoldAtViewLine(view_line);
        if (changed) self.invalidate();
        return changed;
    }

    fn positionAtCell(self: *const View, view_line: usize, x: usize) !Position {
        const gutter = self.editor.gutterWidth();
        const signed: isize = @as(isize, @intCast(x)) - @as(isize, @intCast(gutter)) +
            @as(isize, @intCast(self.editor.scrollLeft()));
        const offset: usize = if (signed <= 0) 0 else @intCast(signed);
        return self.editor.positionAtViewPoint(view_line, offset);
    }

    fn selectFrom(self: *View, anchor: Position, position: Position) !void {
        try self.editor.setSelections(&[_]Selection{
            Selection.init(anchor.lineNumber, anchor.column, position.lineNumber, position.column),
        });
    }

    /// Mirrors the editor's horizontal scroll range into the UI scroll view.
    /// Returns the whole-cell offset actually applied by the view.
    fn syncLineScroll(self: *View, gutter: usize, text_width: usize, text_height: usize) !usize {
        if (!self.line_scroll_ready) return 0;
        const scroll_width = @max(
            text_width,
            @as(usize, @intFromFloat(self.editor.viewLayout().getScrollWidth())),
        );
        const geometry_changed = text_width != self.line_scroll_text_width or
            text_height != self.line_scroll_text_height or
            scroll_width != self.line_scroll_width;
        self.line_scroll.setViewportRect(@floatFromInt(gutter), 0, text_width, text_height);
        self.line_scroll.setContentSize(scroll_width, text_height);
        const wanted: usize = @intFromFloat(self.editor.viewLayout().getCurrentScrollLeft());
        _ = self.line_scroll.scrollToX(wanted);
        self.line_scroll_width = scroll_width;
        self.line_scroll_text_width = text_width;
        self.line_scroll_text_height = text_height;
        const target = self.line_scroll.scrollLeft();
        if ((geometry_changed or target != self.line_scroll_applied) and !self.needs_full_box_rebuild) {
            self.surface.box_tree.markFullRebuild();
            self.needs_full_box_rebuild = true;
        }
        self.line_scroll_applied = target;
        return target;
    }

    /// Brings the ui surface and document in step with the editor viewport.
    /// The surface and retained roots are reused; only the line window is
    /// discarded because the view-line mapping may change with the width.
    fn synchronizeViewport(self: *View) !void {
        const width = self.editor.screen_width;
        const height = self.editor.screen_height;
        const doc = self.surface.document();
        if (doc.cols == width and doc.rows == height) return;

        self.terminal_view_host.viewRef().scrollbarPart().endDrag();
        try self.surface.resize(width, height);
        self.applyTopInset();
        self.terminal_view_host.viewRef().getViewLines().clearWindow();
        doc.tab_size = self.editor.tabSize();
        self.needs_full_box_rebuild = true;
    }

    /// Resets the theme-dependent document roots; the next render recreates
    /// them because the registry colors are cached per document.
    pub fn setThemeColors(self: *View, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme_colors = palette;
        self.terminal_view_host.viewRef().marginPart().setTheme(marginTheme(palette));
        self.clearPaintStyles();
        self.refreshBracketHighlightColors();
        self.document_ready = false;
        self.invalidate();
    }

    /// Drops every retained chrome pointer when the document that owns the
    /// nodes is cleared or replaced. The nodes themselves are not touched.
    fn resetChromeRoots(self: *View) void {
        self.terminal_view_host.viewRef().marginPart().resetNodes();
        self.terminal_view_host.viewRef().scrollbarPart().resetNodes();
        self.chrome_root = null;
        self.gutter_root = null;
        self.scrollbar_root = null;
        self.overlay_widgets_root = null;
        self.content_widgets_root = null;
        self.status_root = null;
        self.status_bar = null;
        self.status_left_text = null;
        self.status_right_box = null;
        self.status_right_text = null;
        self.status_signature = 0;
        self.status_active = false;
        self.status_row = 0;
    }

    fn clearPaintStyles(self: *View) void {
        var iterator = self.paint_styles.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.class.len > 0) self.allocator.free(entry.key_ptr.class);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.paint_styles.clearRetainingCapacity();
    }

    /// Rebuilds the bracket color pool from the active theme. Upstream's
    /// theming participant filters missing/transparent colors and cycles the
    /// remaining ones, so levels 4..6 fall back to the first colors in the
    /// default themes instead of painting transparent cells. The same pass
    /// refreshes the per-level guide colors.
    fn refreshBracketHighlightColors(self: *View) void {
        const fallback = bracketFallbackPalette(self.theme_colors);
        self.bracket_highlight_color_count = 0;
        for (bracket_highlight_ids, 0..) |id, index| {
            var resolved: ?ui.Color = null;
            if (self.theme_colors) |palette| {
                if (palette.rawColor(id)) |raw| {
                    if (raw.a > 0.001) resolved = palette.compositeColor(raw);
                } else if (index < fallback.levels.len) {
                    resolved = color(fallback.levels[index]);
                }
            } else if (index < fallback.levels.len) {
                resolved = color(fallback.levels[index]);
            }
            self.bracket_highlight_by_level[index] = resolved;
            if (resolved) |value| {
                self.bracket_highlight_colors[self.bracket_highlight_color_count] = value;
                self.bracket_highlight_color_count += 1;
            }
        }
        self.unexpected_bracket_color = if (self.theme_colors) |palette|
            palette.color("editorBracketHighlight.unexpectedBracket.foreground", fallback.unexpected)
        else
            color(fallback.unexpected);
        self.refreshBracketGuideColors();
        self.refreshIndentGuideColors();
    }

    /// Upstream `indentGuides.ts` derives bracket-pair guide colors from the
    /// same-level bracket highlight color when the guide-specific color is
    /// transparent/missing: 30% opacity for inactive guides and the full
    /// color for the active pair.
    fn refreshBracketGuideColors(self: *View) void {
        self.bracket_guide_color_count = 0;
        for (0..bracket_guide_ids.len) |index| {
            const bracket_color = self.bracket_highlight_by_level[index];
            const guide = self.resolveThemeColor(bracket_guide_ids[index]);
            const active_guide = self.resolveThemeColor(bracket_guide_active_ids[index]);
            var inactive: ?ui.Color = guide;
            if (inactive == null) {
                if (bracket_color) |value| inactive = self.fadedColor(value, 0.3);
            }
            var active: ?ui.Color = active_guide;
            if (active == null) active = bracket_color;
            if (inactive != null and active != null) {
                self.bracket_guide_colors[self.bracket_guide_color_count] = .{ .inactive = inactive.?, .active = active.? };
                self.bracket_guide_color_count += 1;
            }
        }
    }

    /// Upstream `indentGuides.ts`: `editorIndentGuide.backgroundN` and
    /// `activeBackgroundN` form a cycled pool; the deprecated ids supply
    /// level 1 when the numbered ids are absent. Default themes only define
    /// level 1, so indentation guides stay a single gray unless a theme opts
    /// into per-level colors.
    fn refreshIndentGuideColors(self: *View) void {
        self.indent_guide_color_count = 0;
        for (0..indent_guide_ids.len) |index| {
            var inactive = self.resolveThemeColor(indent_guide_ids[index]);
            var active = self.resolveThemeColor(indent_guide_active_ids[index]);
            if (index == 0) {
                if (inactive == null) inactive = self.resolveThemeColor("editorIndentGuide.background");
                if (active == null) active = self.resolveThemeColor("editorIndentGuide.activeBackground");
            }
            if (inactive != null and active != null) {
                self.indent_guide_colors[self.indent_guide_color_count] = .{ .inactive = inactive.?, .active = active.? };
                self.indent_guide_color_count += 1;
            }
        }
        if (self.indent_guide_color_count == 0) {
            self.indent_guide_colors[0] = .{
                .inactive = color(indent_guide_color),
                .active = color(indent_guide_active_color),
            };
            self.indent_guide_color_count = 1;
        }
    }

    fn resolveThemeColor(self: *const View, id: []const u8) ?ui.Color {
        const palette = self.theme_colors orelse return null;
        const raw = palette.rawColor(id) orelse return null;
        if (raw.a <= 0.001) return null;
        return palette.compositeColor(raw);
    }

    fn fadedColor(self: *const View, value: ui.Color, alpha: f32) ui.Color {
        const background = if (self.theme_colors) |palette| palette.background else color([3]u8{ 30, 30, 33 });
        return fadeOver(value, alpha, background);
    }

    /// Uniform color for rendered whitespace. Upstream's `mtkw` rule uses
    /// `editorWhitespace.foreground`; themes without it inherit the text color
    /// in the browser, which looks too strong in a terminal cell, so the
    /// fallback is the default foreground dimmed over the editor background.
    fn whitespaceColor(self: *const View) ui.Color {
        if (self.resolveThemeColor(whitespace_foreground_id)) |value| return value;
        const foreground = if (self.theme_colors) |palette|
            palette.foreground
        else
            color(default_text_color);
        return self.fadedColor(foreground, whitespace_fallback_alpha);
    }

    /// Extracts the `lvl-N` suffix from an upstream guide class name.
    fn guideLevel(class_name: []const u8) usize {
        const marker = "lvl-";
        const index = std.mem.lastIndexOf(u8, class_name, marker) orelse return 0;
        var value: usize = 0;
        var i = index + marker.len;
        while (i < class_name.len and class_name[i] >= '0' and class_name[i] <= '9') : (i += 1) {
            value = value * 10 + (class_name[i] - '0');
        }
        return value;
    }

    fn bracketGuideColors(self: *const View, level: usize, active: bool) ?ui.Color {
        if (self.bracket_guide_color_count == 0) return null;
        const colors = self.bracket_guide_colors[level % self.bracket_guide_color_count];
        return if (active) colors.active else colors.inactive;
    }

    fn indentGuideColors(self: *const View, level: usize) GuideColors {
        return self.indent_guide_colors[level % self.indent_guide_color_count];
    }

    /// Applies `editor.*` view settings to the ported options and dispatches a
    /// configuration-change view event, then schedules a rebuild. Model-level
    /// settings are applied by the owning editor.
    pub fn applyEditorSettings(
        self: *View,
        reader: terminal_editor_config.Reader,
        language_id: ?[]const u8,
        resource: ?[]const u8,
    ) !bool {
        var changed: terminal_editor_config.ChangeSet = undefined;
        if (!self.terminal_view_host.applyEditorSettings(reader, language_id, resource, &changed)) return false;
        // Configuration changes are a view event, so dispatch them through the
        // editor: every part registered with the `ViewContext` (including
        // `ViewLines`, which caches `ViewLineOptions` per line) receives them,
        // exactly like the upstream view-model event flow. Calling the concrete
        // `View` method directly skipped `ViewLines`, leaving line options such
        // as `renderWhitespace` stale.
        const event = view_events.ViewConfigurationChangedEvent.init(
            editor_options.ConfigurationChangedEvent.init(&changed),
        );
        self.editor.emitViewEvent(.{ .ViewConfigurationChanged = event });
        for (self.configuration_listeners.items) |listener| listener.notify(listener.context);
        self.document_ready = false;
        self.needs_render = true;
        return true;
    }

    /// Content background for the current-line highlight. `gutter` and `none`
    /// leave the content background untouched. The focus-only variant follows
    /// the forwarded View focus state.
    fn currentLineBackground(self: *const View) ?ui.Color {
        if (self.terminal_view_host.options.get(.renderLineHighlightOnlyWhenFocus) and
            !self.terminal_view_host.viewRef().isFocused())
        {
            return null;
        }
        return switch (self.terminal_view_host.options.get(.renderLineHighlight)) {
            .none, .gutter => null,
            .line, .all => if (self.theme_colors) |palette|
                palette.color("editor.lineHighlightBackground", current_line_background)
            else
                color(current_line_background),
        };
    }

    /// Port of the upstream `View.render(now, everything)` entry point.
    /// `now=false` only records that a render is pending; the terminal host
    /// has no animation-frame scheduler, so the caller flushes on paint.
    pub fn render(self: *View, now: bool, everything: bool) !void {
        if (everything) {
            // Upstream forces every view part to render. The terminal parts
            // are always visited by the flush pass, so this only needs to
            // guarantee that a pass happens.
            self.needs_render = true;
        }
        if (!now) {
            self.needs_render = true;
            return;
        }
        if (!self.needs_render) return;
        try self.flushAccumulatedAndRenderNow();
    }

    /// Host convenience used after an input batch: force one immediate render
    /// pass even when no view event marked the document dirty. This is the
    /// terminal equivalent of `render(now, everything)` without forcing a
    /// whole box-tree rebuild.
    pub fn refresh(self: *View) !void {
        self.needs_render = true;
        try self.render(true, false);
    }

    /// The text row of a model position, or null when it is outside the
    /// viewport. Content widgets use this to decide above/below placement.
    pub fn visibleRowOf(self: *View, position: Position) ?usize {
        const view_position = self.editor.viewPositionOfModelPosition(position);
        const top = self.editor.topViewLine();
        if (view_position.lineNumber < top) return null;
        const row = view_position.lineNumber - top;
        if (row >= self.editor.textHeight()) return null;
        return row;
    }

    /// Gives the keyboard back to the editor after a content widget closes.
    pub fn focusEditor(self: *View) void {
        self.surface.document().blur();
    }

    /// Forwards the workbench focus state to the ported View/overlays. This is
    /// the terminal boundary for upstream `View.focus()`/`blur()`.
    pub fn setFocused(self: *View, focused: bool) bool {
        const changed = self.terminal_view_host.viewRef().setFocused(focused);
        if (changed) self.needs_render = true;
        return changed;
    }

    pub fn isFocused(self: *const View) bool {
        return self.terminal_view_host.viewRef().isFocused();
    }

    /// Updates the glyph-margin tooltip from the mouse target. Non-glyph
    /// targets clear it. The message comes from `glyphMarginHoverMessage`.
    pub fn setGlyphHover(self: *View, target: editorBrowser.MouseTarget) void {
        if (target.type != .gutter_glyph_margin) {
            self.clearGlyphHover();
            return;
        }
        const position = target.position orelse {
            self.clearGlyphHover();
            return;
        };
        const lane = target.mouse_column -| 1;
        const tooltip = self.terminal_view_host.glyphTooltipAt(position.lineNumber, lane) orelse {
            self.clearGlyphHover();
            return;
        };
        if (self.glyph_tooltip.visible and
            self.glyph_tooltip.line == position.lineNumber and
            std.mem.eql(u8, self.glyph_tooltip.text(), tooltip))
        {
            return;
        }
        self.glyph_tooltip.line = position.lineNumber;
        self.glyph_tooltip.setText(tooltip);
        self.invalidate();
    }

    pub fn clearGlyphHover(self: *View) void {
        if (!self.glyph_tooltip.visible) return;
        self.glyph_tooltip.clear();
        self.invalidate();
    }

    /// Paints into the view's own frame without writing ANSI. The multi-file
    /// workbench composites this grid below the tab strip.
    pub fn paint(self: *View) !void {
        try self.ensureRendered();
        try self.surface.paintFrame();
    }

    pub fn grid(self: *View) *const ui.CellGrid {
        return self.surface.grid();
    }

    /// Paints the ported `BlockDecorations` ranges into the content layer.
    ///
    /// Upstream creates one positioned DOM block per decoration and styles it
    /// through CSS. The terminal equivalent is one absolute `ui` node per
    /// block; the class-name resolver below is the terminal stand-in for the
    /// upstream CSS rules. Blocks are rebuilt per frame and inserted before
    /// the retained line nodes, so text always paints over them.
    fn paintBlocks(
        self: *View,
        doc: *ui.Document,
        root: *ui.Node,
        host: ?*editorBrowser.RetainedViewPartHost,
        gutter: usize,
        text_width: usize,
        text_height: usize,
    ) !void {
        for (self.block_nodes.items) |node| {
            if (host) |retained| retained.removeSubtree(node);
            doc.destroy(node);
        }
        self.block_nodes.clearRetainingCapacity();
        if (text_height == 0) return;

        const blocks = self.terminal_view_host.blockDecorations().blocksSlice();
        for (blocks) |block| {
            const style = self.blockStyle(block.class_name) orelse continue;
            const padding = block.padding;
            const top_f = block.top - @as(f64, @floatFromInt(padding[0]));
            const bottom_f = block.bottom + @as(f64, @floatFromInt(padding[2]));
            const top: isize = @max(0, @as(isize, @intFromFloat(@round(top_f))));
            const bottom: isize = @min(
                @as(isize, @intCast(text_height)),
                @as(isize, @intFromFloat(@round(bottom_f))),
            );
            if (bottom <= top) continue;

            const left: isize = @max(
                0,
                @as(isize, @intCast(gutter)) - @as(isize, @intCast(padding[3])),
            );
            const right: isize = @min(
                @as(isize, @intCast(doc.cols)),
                @as(isize, @intCast(gutter + text_width + padding[1])),
            );
            if (right <= left) continue;

            var width: usize = @intCast(right - left);
            var height: usize = @intCast(bottom - top);

            // Upstream `.blockDecorations-block` uses `box-sizing: border-box`.
            // `ui` sizes the content box, so subtract the border widths from
            // the requested block size. A one-cell block has no room for a
            // full outline; collapse it to a single edge so it stays visible.
            var border = ui.EdgeDecl{};
            if (style.border_color != null) {
                if (width >= 2 and height >= 2) {
                    border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 };
                    width -= 2;
                    height -= 2;
                } else if (height == 1) {
                    border = .{ .top = 1 };
                    height = 0;
                } else if (width == 1) {
                    border = .{ .left = 1 };
                    width = 0;
                } else {
                    continue;
                }
            }

            const node = try doc.createElement(.div);
            try node.addClass(editor_css.block_decorations.Class.block_decorations_block);
            node.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(left) },
                .top = .{ .cells = @floatFromInt(top) },
                .width = .{ .cells = @floatFromInt(width) },
                .height = .{ .cells = @floatFromInt(height) },
                .background = style.background,
                .border = border,
                .border_color = style.border_color,
            });
            node.setPointerEvents(false);
            _ = try root.appendChild(node);
            if (host) |retained| try retained.addSubtree(node);
            try self.block_nodes.append(node);
        }
    }

    /// Terminal stand-in for the upstream block-decoration CSS classes. Only
    /// the classes with a defined upstream color are mapped; unknown classes
    /// stay invisible, like a class with no CSS rule.
    fn blockStyle(self: *View, class_name: []const u8) ?ui.Style {
        var moved = false;
        var active = false;
        var tokens = std.mem.tokenizeScalar(u8, class_name, ' ');
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "movedOriginal") or std.mem.eql(u8, token, "movedModified")) {
                moved = true;
            } else if (std.mem.eql(u8, token, "currentMove")) {
                active = true;
            }
        }
        if (!moved and !active) return null;

        const border = if (active)
            themedColor(self.theme_colors, "diffEditor.moveActive.border", .{ 255, 165, 0 })
        else
            themedColor(self.theme_colors, "diffEditor.move.border", .{ 139, 139, 139 });
        return .{ .border_color = border };
    }

    /// Renders the surface diff to an ANSI writer. This is the standalone
    /// preview/read-loop entry point; it is not the upstream `View.render`
    /// orchestration entry point.
    pub fn renderAnsi(self: *View, writer: *std.Io.Writer) !void {
        try self.ensureRendered();
        try self.surface.render(writer, .{ .synchronized = true });
    }

    /// The computed pointer shape under an editor-relative cell. Content text
    /// resolves to `.text`; the chrome roots and widget styles override it.
    pub fn pointerAt(self: *View, x: usize, y: usize) !ui.Pointer {
        try self.ensureRendered();
        return (try self.surface.pointerAt(x, y)) orelse .default;
    }

    /// Records the pointer shape for the next `render`. Returns true when it
    /// changed, so the read-only preview can request a redraw.
    pub fn setPointer(self: *View, shape: ui.Pointer) bool {
        return self.surface.setPointer(shape);
    }

    /// Enables OSC 22 emission for the single-surface preview host. The
    /// workbench composites pane surfaces itself and emits at its own frame.
    pub fn setPointerShapes(self: *View, enabled: bool) void {
        self.surface.setPointerShapes(enabled);
    }

    /// The hardware cursor cell, valid after the render pass has laid the tree
    /// out. Returns null when the caret is outside the text area.
    pub fn cursorCell(self: *View) ?Cell {
        self.ensureRendered() catch return null;
        // A focused widget paints its own block caret; the hardware cursor
        // belongs to the editor.
        if (self.surface.document().focusedElement() != null) return null;
        const row = self.cursor_row orelse return null;
        const rows = self.surface.document().rows;
        const cols = self.surface.document().cols;
        if (row >= rows) return null;
        const visible_row = row + self.top_inset_rows;
        if (visible_row >= rows) return null;
        const right = @min(cols, self.editor.textAreaRight());
        const col = @min(self.cursor_col, right -| 1);
        // Overlay widgets (sticky scroll, find) cover the cells beneath them.
        // Hide the hardware cursor when it would be painted under a widget.
        for (self.terminal_view_host.viewRef().overlayWidgets().entries.items) |entry| {
            if (entry.contains(col, visible_row)) return null;
        }
        return .{ .row = visible_row, .col = col };
    }

    /// Terminal cell style adapter for a rendered view-line part. Sticky
    /// scroll reuses it so its header rows get the same syntax/bracket colors
    /// as ordinary lines.
    pub fn lineStyleFunction(self: *View) view_line_mod.ViewLine.PartStyleFn {
        return .{ .context = self, .apply = paintStyleThunk };
    }

    /// Shared paint style for a rendered part, keyed by the CSS-class analogue
    /// (token color + attributes + decoration classes + cell flags). Equal
    /// styles are one object in the text-node DOM.
    fn paintStyleForPart(
        self: *View,
        part: line_renderer.RenderedPart,
        flag: u32,
    ) !*const ui.style.PaintStyle {
        var attrs: u8 = 0;
        if (part.bold) attrs |= 1;
        if (part.italic) attrs |= 2;
        if (part.underline) attrs |= 4;
        if (part.strikethrough) attrs |= 8;
        const key = PaintStyleKey{
            .foreground = part.foreground,
            .attrs = attrs,
            .flags = flag,
            .is_whitespace = part.is_whitespace,
            .class = part.decoration_class orelse "",
        };
        if (self.paint_styles.get(key)) |style| return style;

        var value = paintOfPart(part);
        applyFlagPaint(&value, flag, self.theme_colors);
        // Upstream's colorization classes set the foreground while find/bracket
        // decorations only add a background/border, so the rainbow color
        // survives a highlight.
        if (part.decoration_class) |classes| applyBracketHighlightPaint(&value, classes, self);
        // `viewLines.css` gives `mtkw` its own color with `!important`: uniform
        // whitespace wins over token, selection and bracket colors.
        if (part.is_whitespace) value.color = self.whitespaceColor();

        const class_copy = if (key.class.len > 0) try self.allocator.dupe(u8, key.class) else "";
        errdefer if (class_copy.len > 0) self.allocator.free(class_copy);
        const style = try self.allocator.create(ui.style.PaintStyle);
        errdefer self.allocator.destroy(style);
        style.* = value;
        try self.paint_styles.put(self.allocator, .{
            .foreground = key.foreground,
            .attrs = key.attrs,
            .flags = key.flags,
            .is_whitespace = key.is_whitespace,
            .class = class_copy,
        }, style);
        return style;
    }

    /// Maps a view-line decoration class list to terminal cell flags. Sticky
    /// scroll passes this to `ViewLine.paint` so inline decorations on a
    /// header line keep their cell styling.
    pub fn decorationBitsFunction(self: *View) *const fn (classes: []const u8) u32 {
        _ = self;
        return decorationBits;
    }

    /// Whether no overlay or content widget owns the keyboard. Word
    /// occurrence highlighting follows the editor's text focus.
    pub fn hasEditorFocus(self: *const View) bool {
        for (self.terminal_view_host.viewRef().overlayWidgets().widgets.items) |overlay| {
            if (overlay.is_focused(overlay.context)) return false;
        }
        for (self.terminal_view_host.viewRef().contentWidgets().widgets.items) |widget| {
            if (widget.is_focused(widget.context)) return false;
        }
        return true;
    }

    /// Port of upstream `View._flushAccumulatedAndRenderNow`: prepare the
    /// editor, render the visible lines, then the retained chrome parts and
    /// their boxes.
    fn flushAccumulatedAndRenderNow(self: *View) !void {
        self.render_count += 1;
        // Reserve or release the glyph-margin cell before the frame computes
        // its gutter and wrapping geometry.
        self.terminal_view_host.prepareFrame();
        try self.synchronizeViewport();
        const editor = self.editor;
        editor.setScrollbarWidth(overviewRulerWidth(editor));
        self.scrollbar_width = editor.scrollbar_width;
        editor.ensureTokensVisible();
        // Colorization decorations are derived from the bracket AST, so it
        // must exist before line decorations are resolved. Small documents
        // build it here; a large document's initial build is deferred and the
        // decorations are refreshed by the AST's change event.
        const bracket_ast_deferred = editor.prepareBracketPairs(time_compat.milliTimestamp());
        // Folding is scheduled by the debounced main-loop pass; rebuilding
        // must not block on a full-document range scan.
        // The cursor is revealed by cursor moves and edits, not on every
        // rebuild: a wheel scroll is allowed to leave it off-screen.
        _ = editor.scrollViewLines(0);

        // A bracket-match query builds the AST when colorization is enabled.
        // While the initial large-document build is deferred, leave the
        // bracket highlight for the frame after the maintenance pass instead
        // of forcing that build from paint.
        if (!bracket_ast_deferred) {
            const bracket_data = try editor.updateBracketMatches(self.hasEditorFocus());
            const bracket_generation = editor.bracketMatchGeneration();
            if (self.last_bracket_generation == null or self.last_bracket_generation.? != bracket_generation) {
                var bracket_decorations = std.array_list.Managed(editorBrowser.Decoration).init(self.allocator);
                defer bracket_decorations.deinit();
                // `editor.matchBrackets: "never"` drops the highlight but still
                // advances the generation so the previous decorations are cleared.
                if (self.terminal_view_host.options.get(.matchBrackets) != .never) {
                    for (bracket_data) |entry| {
                        const brackets = entry.brackets orelse continue;
                        const overview = entry.options == .with_overview_ruler;
                        try bracket_decorations.append(.{
                            .range = brackets[0],
                            .kind = .bracket_match,
                            .show_in_overview_ruler = overview,
                        });
                        try bracket_decorations.append(.{
                            .range = brackets[1],
                            .kind = .bracket_match,
                            .show_in_overview_ruler = overview,
                        });
                    }
                }
                try self.replaceModelDecorations(DecorationOwner.bracket, bracket_decorations.items);
                self.last_bracket_generation = bracket_generation;
            }
        }

        const doc = self.surface.document();
        if (!self.document_ready) {
            self.line_scroll_ready = false;
            // Drop the rendered window without touching the old nodes: the
            // whole document is about to be cleared.
            self.terminal_view_host.viewRef().getViewLines().flushWindow();
            doc.clear();
            self.resetChromeRoots();
            const root = try doc.createElement(.div);
            root.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .percent = 100 },
                .height = .{ .percent = 100 },
                .overflow = .hidden,
                .background = if (self.theme_colors) |palette| palette.background else null,
                // The editor content is text: blank cells beyond a line still
                // show the I-beam because they hit the root. Chrome roots
                // override this with the terminal default.
                .pointer = .text,
            });
            doc.setRoot(root);
            const block_root = try doc.createElement(.div);
            block_root.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .percent = 100 },
                .height = .{ .percent = 100 },
            });
            try block_root.addClass(editor_css.block_decorations.Class.block_decorations_container);
            block_root.setPointerEvents(false);
            _ = try root.appendChild(block_root);
            const content_root = try doc.createElement(.div);
            content_root.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .percent = 100 },
                .height = .{ .percent = 100 },
                .pointer = .text,
            });
            content_root.setPointerEvents(false);
            _ = try root.appendChild(content_root);

            self.line_scroll_applied = 0;
            self.line_scroll_width = 0;
            self.line_scroll_text_width = 0;
            self.line_scroll_text_height = 0;
            try self.line_scroll.init(doc, content_root, .{
                .width = 1,
                .height = 1,
                .content_width = 1,
                .content_height = 1,
                .scrollbar = false,
                .horizontal_scrollbar = false,
                .on_scroll = .{ .context = self, .callback = lineScrollCallback },
            });
            self.line_scroll_ready = true;
            try self.line_scroll.contentNode().addClass(editor_css.view_lines.Class.view_lines);

            const chrome_root = try doc.createElement(.div);
            chrome_root.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .percent = 100 },
                .height = .{ .percent = 100 },
                .pointer = .default,
            });
            chrome_root.setPointerEvents(false);
            _ = try root.appendChild(chrome_root);
            self.root_node = root;
            self.content_root = content_root;
            self.block_root = block_root;
            self.block_nodes.clearRetainingCapacity();
            self.chrome_root = chrome_root;
            // The retained chrome parts manage their own containers, in paint
            // order: gutter, scrollbar, overlay widgets, content widgets and
            // the editor status row.
            self.gutter_root = try appendChromePartRoot(doc, chrome_root);
            self.scrollbar_root = try appendChromePartRoot(doc, chrome_root);
            self.overlay_widgets_root = try appendChromePartRoot(doc, chrome_root);
            try self.overlay_widgets_root.?.addClass(editor_css.overlay_widgets.Class.overlay_widgets);
            self.content_widgets_root = try appendChromePartRoot(doc, chrome_root);
            self.status_root = try appendChromePartRoot(doc, chrome_root);
            self.applyTopInset();
            self.document_ready = true;
            self.needs_full_box_rebuild = true;
            self.terminal_view_host.viewRef().getViewLines().setDomHost(
                doc,
                self.line_scroll.contentNode(),
                self,
                viewLineDisposed,
            );
        }
        // Retained chrome: each part updates its own stable container below
        // instead of clearing the whole chrome root every frame.
        self.cursor_row = null;
        self.cursor_col = 0;

        const cols = doc.cols;
        const rows = doc.rows;
        const scrollbar_width = if (self.scrollbar_width > 0 and
            cols > editor.gutterWidth() + self.scrollbar_width)
            self.scrollbar_width
        else
            0;
        self.scrollbar_width = scrollbar_width;
        const gutter = @min(editor.gutterWidth(), cols -| scrollbar_width);
        const text_width = @max(@as(usize, 1), cols -| gutter -| scrollbar_width);
        const text_right = @min(cols, gutter + text_width);
        const text_height = editor.textHeight();
        const total = editor.viewLineCount();
        const top = editor.topViewLine();
        const tab_size = editor.tabSize();

        // Terminal performance gate: while a large document's bracket AST is
        // deferred, the ported overlay skips bracket guides but still paints
        // indentation guides and the active indentation scope.
        const defer_bracket_guides = editor.shouldDeferBracketGuides();
        if (defer_bracket_guides) editor.scheduleBracketGuides(time_compat.milliTimestamp());
        self.terminal_view_host.indentGuides().setBracketGuidesEnabled(!defer_bracket_guides);

        if (top <= total) {
            try self.terminal_view_host.renderViewport();
        }
        const scroll_left = try self.syncLineScroll(gutter, text_width, text_height);
        const content_scroll_width = @max(
            text_width,
            @as(usize, @intFromFloat(editor.viewLayout().getScrollWidth())),
        );

        var guide_specs = std.array_list.Managed(GuideSpec).init(self.allocator);
        defer guide_specs.deinit();

        if (top <= total) {
            // The ported `IndentGuidesOverlay` has already merged indent
            // guides, the active indentation scope and bracket-pair guides in
            // upstream order. The terminal compositor only owns the cell
            // mapping: a guide is painted in a leading-whitespace cell of a
            // model line's first row; wrapped continuation rows are skipped.
            const guides_overlay = self.terminal_view_host.indentGuides();
            const end_view_line = @min(total, top + text_height -| 1);
            var view_line = top;
            while (view_line <= end_view_line) : (view_line += 1) {
                if (editor.view_lines.getOutputLineIndex(view_line) != 0) continue;
                const line_guides = guides_overlay.renderedLine(view_line) orelse continue;
                const row = view_line - top;
                const model_line = editor.modelLineNumber(view_line);
                var content = try editor.model.getLineContent(model_line);
                defer content.deinit();
                const indent_width = computeIndentLevel(content.items, tab_size);
                for (line_guides) |guide| {
                    // Horizontal guide segments need a multi-cell horizontal
                    // line; the terminal guide layer only paints verticals.
                    if (guide.horizontalLine != null) continue;
                    if (guide.visibleColumn < 0) continue;
                    const column: usize = @intCast(guide.visibleColumn - 1);
                    if (column >= text_width) continue;
                    if (indent_width >= 0 and column >= @as(usize, @intCast(indent_width))) continue;
                    const level = guideLevel(guide.className);
                    const active = std.mem.indexOf(u8, guide.className, "indent-active") != null;
                    const guide_color = if (std.mem.startsWith(u8, guide.className, "core-guide-indent"))
                        rgbOf(if (active) self.indentGuideColors(level).active else self.indentGuideColors(level).inactive)
                    else
                        rgbOf(self.bracketGuideColors(level, active) orelse continue);
                    try guide_specs.append(.{
                        .row = row,
                        .col = column,
                        .color = guide_color,
                    });
                }
            }
        }

        // Rulers are vertical column guides in the browser. The terminal
        // paints the same column through the guide layer only where a text
        // glyph does not occupy the cell.
        const ruler_columns = try rulers_mod.columns(
            self.allocator,
            self.terminal_view_host.options.get(.rulers),
            content_scroll_width,
        );
        defer self.allocator.free(ruler_columns);
        if (ruler_columns.len > 0) {
            const ruler_color = themedColor(self.theme_colors, "editorRuler.foreground", .{ 90, 90, 90 });
            for (ruler_columns) |column| {
                var ruler_row: usize = 0;
                while (ruler_row < text_height) : (ruler_row += 1) {
                    const view_line = top + ruler_row;
                    if (view_line > total) break;
                    const model_line = self.editor.modelLineNumber(view_line);
                    var content = try self.editor.model.getLineContent(model_line);
                    defer content.deinit();
                    if (column < content.items.len and content.items[column] != ' ' and content.items[column] != '\t') {
                        continue;
                    }
                    try guide_specs.append(.{
                        .row = ruler_row,
                        .col = column,
                        .color = rgbOf(ruler_color),
                    });
                }
            }
        }

        _ = self.content_root orelse return error.DocumentRootMissing;
        const block_root = self.block_root orelse return error.DocumentRootMissing;
        const gutter_root = self.gutter_root orelse return error.DocumentRootMissing;
        const scrollbar_root = self.scrollbar_root orelse return error.DocumentRootMissing;
        const overlay_widgets_root = self.overlay_widgets_root orelse return error.DocumentRootMissing;
        const content_widgets_root = self.content_widgets_root orelse return error.DocumentRootMissing;
        const status_root = self.status_root orelse return error.DocumentRootMissing;
        // A full box solve rebuilds every box from the DOM; only incremental
        // frames need the explicit retained-part operations.
        var chrome_host = editorBrowser.RetainedViewPartHost{
            .tree = self.surface.box_tree,
            .doc = doc,
        };
        const chrome_host_ptr: ?*editorBrowser.RetainedViewPartHost =
            if (self.needs_full_box_rebuild) null else &chrome_host;
        const states = try editor.viewCursorStates();
        defer editor.allocator.free(states);
        const cursor_render_data = self.terminal_view_host.getCursorRenderData();
        const cursor = if (cursor_render_data.len > 0)
            cursor_render_data[0].position
        else
            states[0].viewState.position;

        self.cursor_row = null;
        if (cursor.lineNumber >= top and cursor.lineNumber < top + text_height and
            cursor.lineNumber <= total)
        {
            const cursor_data = editor.viewLineData(cursor.lineNumber) catch null;
            if (cursor_data) |data| {
                const cursor_model_line = editor.modelLineNumber(cursor.lineNumber);
                var content = editor.model.getLineContent(cursor_model_line) catch null;
                if (content) |*owned| {
                    defer owned.deinit();
                    const visible = visibleOffset(
                        owned.items,
                        cursor.column,
                        tab_size,
                        data.startVisibleColumn,
                        data.minColumn - 1,
                    );
                    if (visible >= scroll_left and visible < scroll_left + text_width) {
                        self.cursor_row = cursor.lineNumber - top;
                        self.cursor_col = gutter + (visible - scroll_left);
                    }
                }
            }
        }

        var paint_guides = std.array_list.Managed(TerminalViewHost.PaintGuide).init(self.allocator);
        defer paint_guides.deinit();
        for (guide_specs.items) |spec| {
            try paint_guides.append(.{ .row = spec.row, .column = spec.col, .color = spec.color });
        }

        // Whole-line diff/quick-diff backgrounds are cell colors because the
        // terminal has no CSS. The ported `DecorationsOverlay` supplies the
        // class list per visible view line.
        const line_backgrounds = try self.allocator.alloc(?ui.Color, text_height);
        defer self.allocator.free(line_backgrounds);
        @memset(line_backgrounds, null);
        if (top <= total) {
            if (text_height > 0 and scroll_decoration.isVisible(top)) {
                line_backgrounds[0] = scroll_decoration.shadowColor(
                    themedColor(self.theme_colors, "scrollbar.shadow", .{ 0, 0, 0 }),
                );
            }
            const end_view_line = @min(total, top + text_height -| 1);
            var view_line = top;
            while (view_line <= end_view_line) : (view_line += 1) {
                if (lineBackground(self.terminal_view_host.decorationsForLine(view_line))) |rgb| {
                    line_backgrounds[view_line - top] = color(rgb);
                }
            }
        }

        try self.paintBlocks(doc, block_root, chrome_host_ptr, gutter, text_width, text_height);
        try self.terminal_view_host.paintViewport(.{
            .doc = doc,
            .root = self.line_scroll.contentNode(),
            .left_cells = 0,
            .width_cells = content_scroll_width,
            .top_row = 0,
            .guides = paint_guides.items,
            .top = top,
            .tab_size = tab_size,
            .text_width = text_width,
            .cursor = cursor,
            .states = states,
            .style_fn = .{ .context = self, .apply = paintStyleThunk },
            .decoration_bits_fn = decorationBits,
            .line_backgrounds = line_backgrounds,
            .selected_flag = CellFlag.selected,
            .secondary_cursor_flag = CellFlag.secondary_cursor,
            .background_color = self.currentLineBackground(),
            .ellipsis_style = .{ .color = color(continuation_color) },
        });

        try self.terminal_view_host.viewRef().renderDocumentParts(.{
            .doc = doc,
            .gutter_root = gutter_root,
            .scrollbar_root = scrollbar_root,
            .overlay_widgets_root = overlay_widgets_root,
            .content_widgets_root = content_widgets_root,
            .host = chrome_host_ptr,
            .editor = editor,
            .states = states,
            .cols = cols,
            .text_height = text_height,
            .text_right = text_right,
            .gutter = gutter,
            .tab_size = tab_size,
            .scroll_left = scroll_left,
            .scrollbar_width = self.scrollbar_width,
            .line_numbers = &self.terminal_view_host.line_numbers,
            .line_decorations = &self.terminal_view_host.line_decorations,
            .glyph_margin = self.terminal_view_host.glyphMargin(),
            .line_highlight = self.terminal_view_host.currentLineMargin(),
            .margin_decorations = self.terminal_view_host.marginDecorations(),
            .folding = self.terminal_view_host.foldingDecorations(),
        });
        try updateStatus(self, doc, chrome_host_ptr, status_root, rows);
        self.perf.chrome_subtrees_added += chrome_host.ops.added;
        self.perf.chrome_subtrees_rebuilt += chrome_host.ops.rebuilt;
        self.perf.chrome_subtrees_translated += chrome_host.ops.translated;
        self.perf.chrome_subtrees_removed += chrome_host.ops.removed;
        if (chrome_host.ops.total() > 0) self.perf.chrome_rebuilds += 1;
        if (chrome_host.failed) self.needs_full_box_rebuild = true;
        try self.syncBoxes(doc);
        self.needs_render = false;
    }

    /// Brings the box tree/layout in step with the retained DOM. The view owns
    /// this invalidation (the box tree's automatic observer is off), mirroring
    /// WebKit's dirty-subtree model: new lines get a box, changed lines rebuild
    /// their children, moved lines translate, removed lines were dropped by
    /// `viewLineDisposed`.
    fn syncBoxes(self: *View, doc: *ui.Document) !void {
        const tree = self.surface.box_tree;
        if (self.needs_full_box_rebuild) {
            try tree.rebuild(doc);
            try @import("ui").layout.layoutTree(tree, doc);
            tree.setAutoInvalidate(false);
            self.needs_full_box_rebuild = false;
            self.perf.full_box_solves += 1;
            // The full solve already built every line box, including the ones
            // painted this frame; consume their dirty flags so the next refresh
            // does not rebuild them as if only their children had changed.
            const lines = self.terminal_view_host.viewRef().getViewLines();
            const start = lines.windowStart();
            const end = lines.windowEnd();
            if (start != 0) {
                var line_number = start;
                while (line_number <= end) : (line_number += 1) _ = lines.lineAt(line_number).takeChildrenDirty();
            }
            return;
        }

        self.perf.incremental_syncs += 1;
        // The retained chrome parts already applied their explicit box deltas
        // while rendering; only the windowed line pass remains here.

        const lines = self.terminal_view_host.viewRef().getViewLines();
        const start = lines.windowStart();
        const end = lines.windowEnd();
        if (start == 0 or end < start) return;

        var line_number = start;
        while (line_number <= end) : (line_number += 1) {
            const line = lines.lineAt(line_number);
            const node = line.dom_node orelse continue;
            const existing = tree.find(node);
            if (existing == null) {
                const added = (try tree.addSubtree(node)) orelse {
                    self.needs_full_box_rebuild = true;
                    return;
                };
                try @import("ui").layout.layoutSubtree(tree, doc, added);
                self.perf.line_added += 1;
            } else if (line.takeChildrenDirty()) {
                const box = try tree.rebuildSubtree(node) orelse {
                    self.needs_full_box_rebuild = true;
                    return;
                };
                // The element background/geometry may have changed with the
                // children; refresh the box style before solving.
                _ = tree.translateSubtree(node, 0, 0);
                try @import("ui").layout.layoutSubtree(tree, doc, box);
                self.perf.line_rebuilt += 1;
            } else {
                const dy = line.paintedTop() - existing.?.rect.y;
                _ = tree.translateSubtree(node, 0, dy);
                self.perf.line_translated += 1;
            }
        }

        // The chrome is still rebuilt in place every frame, so its box arena
        // grows until the next full solve. Rebuild the box tree (not the DOM)
        // when it grows too large; a document reset is only needed when the
        // DOM arena itself crosses its bound.
        if (tree.arena.queryCapacity() > 32 * 1024 * 1024) {
            self.needs_full_box_rebuild = true;
        }
        if (doc.arena.queryCapacity() > 64 * 1024 * 1024) {
            self.document_ready = false;
            self.needs_full_box_rebuild = true;
        }
    }

    /// Test/diagnostic access to the overview markers produced by the ported
    /// scrollbar part.
    fn appendOverviewMarkers(
        self: *View,
        markers: *std.array_list.Managed(decorationsOverviewRuler.Decoration),
    ) !void {
        try editor_scrollbar_mod.appendOverviewMarkers(markers, self.editor, self.allocator);
    }
};

/// Two cells when there is room for them plus at least one text column. The
/// marker and thumb layers share these cells. Very narrow terminals keep their
/// text instead.
fn overviewRulerWidth(editor: *const Editor) usize {
    return Editor.overviewRulerWidthFor(editor.screen_width, editor.gutterWidth());
}

fn lineScrollCallback(context: ?*anyopaque, left: usize, top: usize) void {
    _ = top;
    const self: *View = @ptrCast(@alignCast(context orelse return));
    _ = self.editor.setScrollLeft(left);
    self.invalidate();
}

fn viewLineDisposed(context: *anyopaque, line: *ViewLine) void {
    const self: *View = @ptrCast(@alignCast(context));
    if (line.dom_node) |node| {
        self.surface.box_tree.removeSubtree(node);
        self.surface.document().destroy(node);
        line.dom_node = null;
    }
}

/// Keeps the editor's fallback status row as a stable node. Only the left and
/// right text nodes are re-pointed at the view's status buffers, and only when
/// the text signature changes; the row itself is never recreated per frame.
fn updateStatus(
    view: *View,
    doc: *ui.Document,
    host: ?*editorBrowser.RetainedViewPartHost,
    root: *ui.Node,
    rows: usize,
) !void {
    const active = rows > 0 and view.status_bar_visible and
        (view.status_left_len > 0 or view.status_right_len > 0);
    if (!active) {
        const bar = view.status_bar orelse return;
        if (bar.asElement().style.display != .none) {
            bar.asElement().style.display = .none;
            view.status_active = false;
            view.status_signature = 0;
            if (host) |retained| try retained.rebuildSubtree(root);
        }
        return;
    }

    const signature = statusSignature(view);
    if (view.status_bar == null) {
        try createStatusRow(view, doc, root, rows);
        view.status_signature = signature;
        view.status_active = true;
        if (host) |retained| try retained.rebuildSubtree(root);
        return;
    }

    var changed = false;
    const bar = view.status_bar.?;
    if (!view.status_active) {
        bar.asElement().style.display = .block;
        view.status_active = true;
        changed = true;
    }
    if (view.status_row != rows - 1) {
        view.status_row = rows - 1;
        bar.asElement().style.top = .{ .cells = @floatFromInt(view.status_row) };
        changed = true;
    }
    if (view.status_signature != signature) {
        view.status_left_text.?.setTextBorrowed(view.status_left[0..view.status_left_len]);
        view.status_right_text.?.setTextBorrowed(view.status_right[0..view.status_right_len]);
        view.status_signature = signature;
        changed = true;
    }
    if (changed) {
        if (host) |retained| try retained.rebuildSubtree(root);
    }
}

fn createStatusRow(view: *View, doc: *ui.Document, root: *ui.Node, rows: usize) !void {
    view.status_row = rows - 1;
    const bar = try doc.createElement(.div);
    bar.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = @floatFromInt(view.status_row) },
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .white_space = .pre,
        .overflow = .hidden,
        .reverse = true,
    });

    const left = try doc.createTextBorrowed(view.status_left[0..view.status_left_len]);
    _ = try bar.appendChild(left);
    view.status_left_text = left;

    const right_box = try doc.createElement(.div);
    right_box.setStyle(.{
        .position = .absolute,
        .right = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .white_space = .pre,
    });
    const right = try doc.createTextBorrowed(view.status_right[0..view.status_right_len]);
    _ = try right_box.appendChild(right);
    _ = try bar.appendChild(right_box);
    view.status_right_box = right_box;
    view.status_right_text = right;

    _ = try root.appendChild(bar);
    view.status_bar = bar;
}

fn statusSignature(view: *const View) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&view.status_left_len));
    hasher.update(view.status_left[0..view.status_left_len]);
    hasher.update(std.mem.asBytes(&view.status_right_len));
    hasher.update(view.status_right[0..view.status_right_len]);
    return hasher.final();
}

/// Creates one stable chrome part container: a full-viewport, hit-test
/// transparent wrapper. Children keep their own pointer-events, so a click on
/// the text still reaches the content lines painted underneath.
fn appendChromePartRoot(doc: *ui.Document, parent: *ui.Node) !*ui.Node {
    const node = try doc.createElement(.div);
    node.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    node.setPointerEvents(false);
    _ = try parent.appendChild(node);
    return node;
}

/// Terminal paint adapter for one rendered part and its cell flags. The
/// context is the owning `View`, so the theme palette reaches the flag styles.
const BracketFallbackPalette = struct {
    levels: [3][3]u8,
    unexpected: [3]u8,
};

const GuideColors = struct {
    inactive: ui.Color,
    active: ui.Color,
};

fn bracketFallbackPalette(palette: ?*const theme_colors_mod.ThemeColors) BracketFallbackPalette {
    const theme_type = if (palette) |p| p.theme.theme_type else .DARK;
    return switch (theme_type) {
        .DARK => .{ .levels = dark_bracket_highlight_colors, .unexpected = dark_unexpected_bracket_color },
        .LIGHT => .{ .levels = light_bracket_highlight_colors, .unexpected = light_unexpected_bracket_color },
        .HIGH_CONTRAST_DARK => .{ .levels = hc_dark_bracket_highlight_colors, .unexpected = hc_dark_unexpected_bracket_color },
        .HIGH_CONTRAST_LIGHT => .{ .levels = light_bracket_highlight_colors, .unexpected = hc_light_unexpected_bracket_color },
    };
}

fn bracketHighlightingLevel(class_name: []const u8) ?usize {
    const prefix = "bracket-highlighting-";
    if (!std.mem.startsWith(u8, class_name, prefix)) return null;
    const digits = class_name[prefix.len..];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

/// Terminal replacement for the CSS rules registered by the upstream
/// colorization provider: the class name chooses a foreground color. Flags
/// are applied first because their terminal styles also set a foreground
/// (an adaptation), whereas upstream foreground comes from the colorization
/// class and the decoration only contributes background/border.
fn applyBracketHighlightPaint(style: *ui.style.PaintStyle, classes: []const u8, view: *const View) void {
    var iterator = std.mem.splitScalar(u8, classes, ' ');
    while (iterator.next()) |class_name| {
        if (std.mem.eql(u8, class_name, "unexpected-closing-bracket")) {
            style.color = view.unexpected_bracket_color;
            return;
        }
        if (bracketHighlightingLevel(class_name)) |level| {
            if (view.bracket_highlight_color_count > 0) {
                style.color = view.bracket_highlight_colors[level % view.bracket_highlight_color_count];
            }
            return;
        }
    }
}

fn paintStyleThunk(
    context: ?*anyopaque,
    part: line_renderer.RenderedPart,
    flag: u32,
) anyerror!*const ui.style.PaintStyle {
    const view: *View = @ptrCast(@alignCast(context orelse return &default_paint_style));
    return view.paintStyleForPart(part, flag);
}

fn marginTheme(palette: ?*const theme_colors_mod.ThemeColors) margin_mod.Theme {
    return .{
        .line_number = themedColor(palette, "editorLineNumber.foreground", .{ 110, 110, 110 }),
        .line_number_active = themedColor(palette, "editorLineNumber.activeForeground", .{ 204, 204, 204 }),
        .continuation = themedColor(palette, "editorLineNumber.foreground", .{ 90, 90, 90 }),
        .filler = themedColor(palette, "editorLineNumber.foreground", .{ 70, 70, 70 }),
        .folding_control = themedColor(palette, "editorGutter.foldingControlForeground", .{ 110, 110, 110 }),
        .current_line_background = themedColor(palette, "editor.lineHighlightBackground", .{ 40, 40, 40 }),
        .added_primary = themedColor(palette, "editorGutter.addedBackground", .{ 72, 126, 2 }),
        .modified_primary = themedColor(palette, "editorGutter.modifiedBackground", .{ 137, 85, 3 }),
        .deleted_primary = themedColor(palette, "editorGutter.deletedBackground", .{ 173, 7, 7 }),
        .added_secondary = themedColor(palette, "editorGutter.addedBackground", .{ 47, 75, 6 }),
        .modified_secondary = themedColor(palette, "editorGutter.modifiedBackground", .{ 84, 54, 6 }),
        .deleted_secondary = themedColor(palette, "editorGutter.deletedBackground", .{ 98, 11, 11 }),
    };
}

fn themedColor(palette: ?*const theme_colors_mod.ThemeColors, id: []const u8, fallback: [3]u8) ui.Color {
    const colors = palette orelse return color(fallback);
    return colors.color(id, fallback);
}

/// Per-theme-type selection literals. High-contrast themes carry a foreground:
/// upstream paints them with `editor.selectionForeground` (the
/// `inline-selected-text` rule) instead of lowering the text contrast.
const SelectionFallback = struct {
    background: [3]u8,
    foreground: ?[3]u8 = null,
};

fn selectionFallback(theme_type: theme_mod.ColorScheme) SelectionFallback {
    return switch (theme_type) {
        .DARK => .{ .background = selection_background_dark },
        .LIGHT => .{ .background = selection_background_light },
        .HIGH_CONTRAST_DARK => .{
            .background = selection_background_hc_dark,
            .foreground = selection_foreground_hc_dark,
        },
        .HIGH_CONTRAST_LIGHT => .{
            .background = selection_background_hc_light,
            .foreground = selection_foreground_hc_light,
        },
    };
}

/// Terminal replacement for the browser's selection layer
/// (`SelectionsOverlay` + `selections.css`). Upstream paints the selection as a
/// translucent background below the text, so the glyphs keep their syntax
/// colors. A cell has one glyph and no alpha channel, so the selection becomes
/// an explicit background and the covered glyph is composited toward it; high
/// contrast themes use the opaque `editor.selectionForeground`, mirroring the
/// `inline-selected-text` CSS rule. Never sets `reverse`: the terminal
/// inverse-video attribute is what made guide cells drop out of the band and
/// look black.
fn applySelectionPaint(style: *ui.style.PaintStyle, palette: ?*const theme_colors_mod.ThemeColors) void {
    const theme_type = if (palette) |colors| colors.theme.theme_type else .DARK;
    const fallback = selectionFallback(theme_type);
    const background = themedColor(palette, "editor.selectionBackground", fallback.background);
    style.background = background;

    if (fallback.foreground) |foreground| {
        style.color = themedColor(palette, "editor.selectionForeground", foreground);
        return;
    }
    const text = style.color orelse (if (palette) |colors| colors.foreground else color(default_text_color));
    style.color = fadeOver(text, selection_text_alpha, background);
}

fn applyFlagPaint(style: *ui.style.PaintStyle, flag: u32, palette: ?*const theme_colors_mod.ThemeColors) void {
    // The browser adds `SelectionsOverlay` before `DecorationsOverlay`, so the
    // selection paints first and any decoration background/foreground below
    // keeps precedence (find matches stay visible inside a selection).
    if (flag & CellFlag.selected != 0) applySelectionPaint(style, palette);
    if (flag & CellFlag.search_range_highlight != 0) {
        style.background = themedColor(palette, "editor.rangeHighlightBackground", search_range_highlight_background);
    }
    if (flag & CellFlag.word_highlight_text != 0) {
        style.background = themedColor(palette, "editor.wordHighlightBackground", word_highlight_background);
    } else if (flag & CellFlag.word_highlight != 0) {
        style.background = themedColor(palette, "editor.wordHighlightBackground", word_highlight_background);
    } else if (flag & CellFlag.word_highlight_strong != 0) {
        style.background = themedColor(palette, "editor.wordHighlightStrongBackground", word_highlight_strong_background);
    }
    if (flag & CellFlag.hover_highlight != 0) {
        style.background = themedColor(palette, "editor.hoverHighlightBackground", hover_highlight_background);
    }
    if (flag & CellFlag.bracket_match != 0) {
        style.background = themedColor(palette, "editorBracketMatch.background", bracket_match_background);
        style.color = themedColor(palette, "editorBracketMatch.border", bracket_match_foreground);
        style.underline = true;
    }
    if (flag & CellFlag.current_find_match != 0) {
        style.background = themedColor(palette, "editor.findMatchBackground", current_find_match_background);
        style.color = themedColor(palette, "editor.findMatchForeground", current_find_match_foreground);
    } else if (flag & CellFlag.find_match != 0) {
        style.background = themedColor(palette, "editor.findMatchHighlightBackground", find_match_background);
    } else if (flag & CellFlag.find_scope != 0) {
        style.background = themedColor(palette, "editor.findRangeHighlightBackground", find_scope_background);
    }
    if (flag & CellFlag.snippet_placeholder != 0) {
        style.background = themedColor(palette, "editor.snippetTabstopHighlightBackground", snippet_placeholder_background);
    } else if (flag & CellFlag.finish_snippet_placeholder != 0) {
        style.background = themedColor(palette, "editor.snippetFinalTabstopHighlightBackground", finish_snippet_placeholder_background);
    }
    if (flag & CellFlag.value_set_replacement != 0) {
        style.color = themedColor(palette, "editorBracketMatch.border", bracket_match_foreground);
        style.underline = true;
    }
    if (flag & CellFlag.diagnostic_error != 0) {
        style.color = themedColor(palette, "editorError.foreground", diagnostic_error_color);
        style.underline = true;
        style.underline_style = .curly;
    } else if (flag & CellFlag.diagnostic_warning != 0) {
        style.color = themedColor(palette, "editorWarning.foreground", diagnostic_warning_color);
        style.underline = true;
        style.underline_style = .curly;
    } else if (flag & CellFlag.diagnostic_info != 0) {
        style.color = themedColor(palette, "editorInfo.foreground", diagnostic_info_color);
        style.underline = true;
        style.underline_style = .curly;
    } else if (flag & CellFlag.diagnostic_hint != 0) {
        style.color = themedColor(palette, "editorHint.foreground", diagnostic_hint_color);
        style.underline = true;
        style.underline_style = .dotted;
    }
    if (flag & CellFlag.diagnostic_unnecessary != 0) {
        style.dim = true;
        style.underline = true;
        style.underline_style = .dashed;
    }
    if (flag & CellFlag.diagnostic_inline_unnecessary != 0) style.dim = true;
    if (flag & CellFlag.diagnostic_deprecated != 0) style.strikethrough = true;
    if (flag & CellFlag.char_insert != 0) {
        style.background = themedColor(palette, "diffEditor.insertedTextBackground", diff_insert_char_background);
    } else if (flag & CellFlag.char_delete != 0) {
        style.background = themedColor(palette, "diffEditor.removedTextBackground", diff_delete_char_background);
    }
    if (flag & CellFlag.secondary_cursor != 0) {
        style.reverse = true;
        style.background = themedColor(palette, "editorCursor.foreground", secondary_cursor_background);
    }
}

fn visibleOffset(
    model_content: []const u8,
    column: usize,
    tab_size: usize,
    start_visible_column: usize,
    indent_cells: usize,
) usize {
    const visible = CursorColumns.visibleColumnFromColumn(model_content, column, tab_size);
    return (visible -| start_visible_column) + indent_cells;
}

fn paintOfPart(part: line_renderer.RenderedPart) ui.style.PaintStyle {
    var paint = ui.style.PaintStyle{
        .bold = part.bold,
        .italic = part.italic,
        .underline = part.underline,
        .strikethrough = part.strikethrough,
    };
    if (colorForToken(part.foreground)) |rgb| {
        paint.color = color(rgb);
    }
    return paint;
}

/// Token color lookup for the terminal view. The fallback palette keeps the
/// standalone view and tests readable before a theme is installed; the real
/// colors come from the active `TokenTheme` color map.
fn colorForToken(foreground: u9) ?[3]u8 {
    if (tokenization.TokenizationRegistry.instance.getColorForToken(foreground)) |c| {
        return .{ c.r, c.g, c.b };
    }
    return switch (foreground) {
        5 => .{ 106, 153, 85 },
        6 => .{ 206, 145, 120 },
        7 => .{ 209, 105, 105 },
        8 => .{ 197, 134, 192 },
        9 => .{ 181, 206, 168 },
        10 => .{ 220, 220, 170 },
        11 => .{ 78, 201, 176 },
        12 => .{ 156, 220, 254 },
        else => null,
    };
}

/// Maps a whole-line decoration class list to a terminal row background.
/// Later classes win, matching the ascending zIndex/class sort of the ported
/// `DecorationsOverlay`.
fn lineBackground(decorations: []const @import("../vs/editor/browser/viewParts/decorations/decorations.zig").LineDecoration) ?[3]u8 {
    var result: ?[3]u8 = null;
    for (decorations) |decoration| {
        var iterator = std.mem.tokenizeScalar(u8, decoration.class_name, ' ');
        while (iterator.next()) |class_name| {
            if (std.mem.eql(u8, class_name, "line-insert")) {
                result = diff_insert_line_background;
            } else if (std.mem.eql(u8, class_name, "line-delete")) {
                result = diff_delete_line_background;
            } else if (std.mem.eql(u8, class_name, "diff-filler")) {
                result = diff_filler_background;
            }
        }
    }
    return result;
}

/// Parses the normalizer's merged class-name string (`"c1 c2"`) into cell
/// flags. Unknown classes are ignored; they have no terminal paint rule.
fn decorationBits(classes: []const u8) u32 {
    var bits: u32 = 0;
    var iterator = std.mem.splitScalar(u8, classes, ' ');
    while (iterator.next()) |class_name| {
        if (decorationBit(class_name)) |bit| bits |= bit;
    }
    return bits;
}

fn decorationBit(class_name: []const u8) ?u32 {
    if (std.mem.eql(u8, class_name, "findMatch") or std.mem.eql(u8, class_name, "findMatchInline")) return CellFlag.find_match;
    if (std.mem.eql(u8, class_name, "currentFindMatch") or std.mem.eql(u8, class_name, "currentFindMatchInline")) return CellFlag.current_find_match;
    if (std.mem.eql(u8, class_name, "findScope")) return CellFlag.find_scope;
    if (std.mem.eql(u8, class_name, "bracket-match") or std.mem.eql(u8, class_name, "bracket-match-inline")) return CellFlag.bracket_match;
    if (std.mem.eql(u8, class_name, "hoverHighlight")) return CellFlag.hover_highlight;
    if (std.mem.eql(u8, class_name, "wordHighlightText")) return CellFlag.word_highlight_text;
    if (std.mem.eql(u8, class_name, "wordHighlight")) return CellFlag.word_highlight;
    if (std.mem.eql(u8, class_name, "wordHighlightStrong")) return CellFlag.word_highlight_strong;
    if (std.mem.eql(u8, class_name, "snippet-placeholder")) return CellFlag.snippet_placeholder;
    if (std.mem.eql(u8, class_name, "finish-snippet-placeholder")) return CellFlag.finish_snippet_placeholder;
    if (std.mem.eql(u8, class_name, "valueSetReplacement")) return CellFlag.value_set_replacement;
    if (std.mem.eql(u8, class_name, "rangeHighlight")) return CellFlag.search_range_highlight;
    if (std.mem.eql(u8, class_name, "char-insert")) return CellFlag.char_insert;
    if (std.mem.eql(u8, class_name, "char-delete")) return CellFlag.char_delete;
    if (std.mem.eql(u8, class_name, "squiggly-error")) return CellFlag.diagnostic_error;
    if (std.mem.eql(u8, class_name, "squiggly-warning")) return CellFlag.diagnostic_warning;
    if (std.mem.eql(u8, class_name, "squiggly-info")) return CellFlag.diagnostic_info;
    if (std.mem.eql(u8, class_name, "squiggly-hint")) return CellFlag.diagnostic_hint;
    if (std.mem.eql(u8, class_name, "squiggly-unnecessary")) return CellFlag.diagnostic_unnecessary;
    if (std.mem.eql(u8, class_name, "squiggly-inline-unnecessary")) return CellFlag.diagnostic_inline_unnecessary;
    if (std.mem.eql(u8, class_name, "squiggly-inline-deprecated")) return CellFlag.diagnostic_deprecated;
    // `inline-selected-text` (the high-contrast selection rule) needs no bit:
    // the selected cell flag already carries the selection background and
    // foreground.
    return null;
}

fn ceilDiv(value: usize, divisor: usize) usize {
    return value / divisor + @intFromBool(value % divisor != 0);
}

fn color(rgb: [3]u8) ui.Color {
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

fn rgbOf(value: ui.Color) [3]u8 {
    return .{ value.r, value.g, value.b };
}

/// Terminal cells have no alpha, so upstream's `Color.transparent(0.3)`
/// guide color is composited over the editor background here.
fn fadeOver(value: ui.Color, alpha: f32, background: ui.Color) ui.Color {
    const a = std.math.clamp(alpha, 0, 1);
    const keep = 1 - a;
    return .{
        .r = mixChannel(value.r, background.r, a, keep),
        .g = mixChannel(value.g, background.g, a, keep),
        .b = mixChannel(value.b, background.b, a, keep),
    };
}

fn mixChannel(value: u8, background: u8, alpha: f32, keep: f32) u8 {
    const blended = @as(f32, @floatFromInt(value)) * alpha +
        @as(f32, @floatFromInt(background)) * keep;
    return @intFromFloat(@round(std.math.clamp(blended, 0, 255)));
}

fn rowText(view: *View, allocator: std.mem.Allocator, row: usize) ![]u8 {
    return view.surface.grid().rowText(allocator, row);
}

fn numberedLines(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var buffer: [32]u8 = undefined;
    for (0..count) |index| {
        if (index != 0) try out.append('\n');
        const text = try std.fmt.bufPrint(&buffer, "line{d}", .{index});
        try out.appendSlice(text);
    }
    return out.toOwnedSlice();
}

test "View: text, gutter and status" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 80, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    view.setStatusText("test status", "");
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const row0 = try rowText(view, allocator, 0);
    defer allocator.free(row0);
    try std.testing.expect(std.mem.indexOf(u8, row0, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, row0, "a") != null);

    const row1 = try rowText(view, allocator, 1);
    defer allocator.free(row1);
    try std.testing.expect(std.mem.indexOf(u8, row1, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, row1, "b") != null);

    const status = try rowText(view, allocator, 4);
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "test status") != null);

    const cursor = view.cursorCell().?;
    try std.testing.expectEqual(@as(usize, 0), cursor.row);
    try std.testing.expectEqual(editor.gutterWidth(), cursor.col);
}

test "View: content requests text, chrome requests default" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc", "test.txt", 20, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    view.setStatusText("test status", "");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    // Text cells, the empty space after the line, and the content area below
    // the last line all take the browser's I-beam.
    try std.testing.expectEqual(ui.Pointer.text, try view.pointerAt(editor.gutterWidth(), 0));
    try std.testing.expectEqual(ui.Pointer.text, try view.pointerAt(15, 0));
    try std.testing.expectEqual(ui.Pointer.text, try view.pointerAt(editor.gutterWidth(), 3));

    // Gutter, overview ruler/scrollbar and the status row keep the terminal
    // default; only the content root opts into text.
    try std.testing.expectEqual(ui.Pointer.default, try view.pointerAt(0, 0));
    try std.testing.expectEqual(ui.Pointer.default, try view.pointerAt(editor.screen_width - 1, 0));
    try std.testing.expectEqual(ui.Pointer.default, try view.pointerAt(3, editor.screen_height - 1));
}

test "View: CJK and tab runs keep the caret on the right cell" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "中\tq", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const row = try rowText(view, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "中") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "q") != null);

    // The caret is at column 1, on the first cell after the gutter.
    const cursor = view.cursorCell().?;
    try std.testing.expectEqual(editor.gutterWidth(), cursor.col);
}

test "View: wordWrap off scrolls long lines through the UI scroll view" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "0123456789abcdefghijklmnopqrstuvwxyz",
        "test.txt",
        20,
        3,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    editor.setWordWrapOptions(.off, 80, .Same, false);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    try std.testing.expectEqual(@as(usize, 1), editor.viewLineCount());
    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '0'), grid.cluster[grid.index(gutter, 0)]);

    try std.testing.expect(editor.setScrollLeft(5));
    try view.refresh();
    try view.renderAnsi(&out.writer);
    const scrolled = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '5'), scrolled.cluster[scrolled.index(gutter, 0)]);
    // The gutter stays fixed while the text scrolls.
    const row = try rowText(view, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "1") != null);

    try std.testing.expect(editor.setScrollLeft(0));
    try view.refresh();
    try view.renderAnsi(&out.writer);
    const reset = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '0'), reset.cluster[reset.index(gutter, 0)]);

    // The UI scroll view consumes the horizontal wheel and mirrors its offset
    // back into the editor's ViewLayout through the callback.
    var wheel = ui.MouseEvent{ .kind = .wheel, .x = gutter + 1, .y = 0, .delta_x = 4 };
    _ = try view.dispatchMouse(&wheel);
    try std.testing.expectEqual(@as(usize, 4), editor.scrollLeft());
    try view.refresh();
    try view.renderAnsi(&out.writer);
    const wheeled = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '4'), wheeled.cluster[wheeled.index(gutter, 0)]);

    // Clicking a scrolled cell maps through the same offset.
    var down = ui.MouseEvent{ .kind = .down, .x = gutter, .y = 0, .button = .left };
    _ = try view.dispatchMouse(&down);
    try std.testing.expectEqual(@as(usize, 5), editor.modelCursorPosition().column);

    // Moving the caret to the end reveals the far side of the long line.
    try editor.setCursorPosition(Position.init(1, 36));
    try std.testing.expect(editor.scrollLeft() > 0);
    try view.refresh();
    try view.renderAnsi(&out.writer);
    const tail = view.surface.grid();
    try std.testing.expectEqual(@as(u32, 'o'), tail.cluster[tail.index(gutter, 0)]);

    try editor.setCursorPosition(Position.init(1, 1));
    try view.refresh();
    try view.renderAnsi(&out.writer);
    const head = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '0'), head.cluster[head.index(gutter, 0)]);
}

test "View: wrapped continuation gets a gutter arrow" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "abcdefghij klmno",
        "test.txt",
        12,
        6,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    var found_arrow = false;
    var row: usize = 0;
    while (row < editor.textHeight()) : (row += 1) {
        const text = try rowText(view, allocator, row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "↪") != null) {
            found_arrow = true;
            break;
        }
    }
    try std.testing.expect(found_arrow);
}

test "View: selection paints the theme background and dims covered text" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "hello", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveRight(true);
    try editor.moveRight(true);

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    // No theme is installed: the dark registry default is the selection
    // background and plain text is the terminal default, so the covered glyph
    // is composited from the fallback foreground.
    try std.testing.expectEqual(
        ui.cell.packColor(color(selection_background_dark)),
        grid.bg[grid.index(gutter, 0)],
    );
    try std.testing.expectEqual(
        ui.cell.packColor(color([3]u8{ 154, 167, 179 })),
        grid.fg[grid.index(gutter, 0)],
    );
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(gutter, 0)] & ui.cell.Attr.inverse);

    // The unselected cell keeps the current-line background and no inverse
    // video: only the selection cells are covered.
    try std.testing.expectEqual(
        ui.cell.packColor(color(current_line_background)),
        grid.bg[grid.index(gutter + 2, 0)],
    );
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(gutter + 2, 0)] & ui.cell.Attr.inverse);
}

test "View: selection spans wrapped continuation rows" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    // Six gutter columns and the two-column overview ruler leave five text
    // columns, so this wraps as abcde / fghij.
    const editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 13, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setSelection(Range.init(1, 1, 1, 11));

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());
    // Both visual rows belong to the selected model line; the continuation row
    // must carry the selection background from its first cell.
    try std.testing.expectEqual(
        ui.cell.packColor(color(selection_background_dark)),
        grid.bg[grid.index(gutter, 0)],
    );
    try std.testing.expectEqual(
        ui.cell.packColor(color(selection_background_dark)),
        grid.bg[grid.index(gutter, 1)],
    );
}

test "View: selection uses the installed theme colors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "hello", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveRight(true);
    try editor.moveRight(true);

    const color_utils = @import("../vs/platform/theme/common/colorUtils.zig");
    const color_theme = @import("../vs/workbench/services/themes/common/colorThemeData.zig");
    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    const theme = try color_theme.ColorThemeData.createUnloadedTheme(allocator, &registry, "test-dark", &.{
        .{ "editor.background", "#101010" },
        .{ "editor.foreground", "#e0e0e0" },
        .{ "editor.selectionBackground", "#123456" },
    });
    defer theme.deinit();
    const palette = theme_colors_mod.ThemeColors.init(theme);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    view.setThemeColors(&palette);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    try std.testing.expectEqual(
        ui.cell.packColor(.{ .r = 0x12, .g = 0x34, .b = 0x56 }),
        grid.bg[grid.index(gutter, 0)],
    );
    // `editor.foreground` (#e0e0e0) composited 30% toward the selection color.
    try std.testing.expectEqual(
        ui.cell.packColor(.{ .r = 162, .g = 172, .b = 183 }),
        grid.fg[grid.index(gutter, 0)],
    );
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(gutter, 0)] & ui.cell.Attr.inverse);
}

test "View: high contrast selection uses the selection foreground" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "hello", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveRight(true);
    try editor.moveRight(true);

    const color_utils = @import("../vs/platform/theme/common/colorUtils.zig");
    const color_theme = @import("../vs/workbench/services/themes/common/colorThemeData.zig");
    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    const theme = try color_theme.ColorThemeData.createUnloadedTheme(allocator, &registry, "test-hc-black", &.{
        .{ "editor.background", "#000000" },
        .{ "editor.foreground", "#ffffff" },
        .{ "editor.selectionBackground", "#ffffff" },
    });
    defer theme.deinit();
    const palette = theme_colors_mod.ThemeColors.init(theme);
    try std.testing.expectEqual(theme_mod.ColorScheme.HIGH_CONTRAST_DARK, palette.theme.theme_type);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    view.setThemeColors(&palette);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    try std.testing.expectEqual(
        ui.cell.packColor(.{ .r = 255, .g = 255, .b = 255 }),
        grid.bg[grid.index(gutter, 0)],
    );
    // High contrast keeps the opaque selection foreground, not a blend of
    // `editor.foreground`.
    try std.testing.expectEqual(
        ui.cell.packColor(.{ .r = 0, .g = 0, .b = 0 }),
        grid.fg[grid.index(gutter, 0)],
    );
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(gutter, 0)] & ui.cell.Attr.inverse);
}

test "View: selection shows whitespace markers by default" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a b\tc d", "test.txt", 30, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setSelections(&[_]Selection{Selection.init(1, 1, 1, 5)});

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    // The upstream default (`editor.renderWhitespace: selection`) replaces the
    // covered space with a middot and the covered tab with a rightwards arrow;
    // the whitespace after the selection is untouched.
    const rendered = try rowText(view, allocator, 0);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "a\u{00B7}b\u{2192}c d") != null);

    // Clearing the selection restores the plain text: the markers are driven by
    // the same selection state the selection background uses.
    try editor.setSelections(&[_]Selection{Selection.init(1, 5, 1, 5)});
    try view.refresh();
    try view.renderAnsi(&out.writer);
    const cleared = try rowText(view, allocator, 0);
    defer allocator.free(cleared);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "a b c d") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "\u{00B7}") == null);
}

test "View: editor.renderWhitespace setting overrides the selection default" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a b c", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setSelections(&[_]Selection{Selection.init(1, 1, 1, 4)});

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const Settings = struct {
        value: std.json.Value = .{ .string = "none" },

        fn get(context: *anyopaque, key: []const u8, _: ?[]const u8, _: ?[]const u8) ?*const std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, key, "editor.renderWhitespace")) return null;
            return &self.value;
        }
    };
    var settings = Settings{};
    _ = try view.applyEditorSettings(.{ .context = &settings, .get_value = Settings.get }, null, null);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const rendered = try rowText(view, allocator, 0);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "a b c") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{00B7}") == null);
}

test "View: refresh keeps the frame diff and the cursor visible" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try view.renderAnsi(&first.writer);
    try std.testing.expect(first.written().len > 0);

    var unchanged: std.Io.Writer.Allocating = .init(allocator);
    defer unchanged.deinit();
    try view.refresh();
    try view.renderAnsi(&unchanged.writer);
    try std.testing.expectEqual(@as(usize, 0), unchanged.written().len);

    try editor.moveDown(false);
    try view.refresh();
    var moved: std.Io.Writer.Allocating = .init(allocator);
    defer moved.deinit();
    try view.renderAnsi(&moved.writer);
    try std.testing.expect(moved.written().len > 0);
    try std.testing.expectEqual(@as(usize, 1), view.cursorCell().?.row);
}

const TestOverlay = struct {
    focused: bool = false,
    node: ?*ui.Node = null,
    keys: usize = 0,

    fn overlay(self: *TestOverlay) editorBrowser.IOverlayWidget {
        return .{
            .context = self,
            .get_id = getId,
            .get_position = getPosition,
            .width = width,
            .height = height,
            .build = build,
            .focus_node = focusNode,
            .is_focused = isFocused,
        };
    }

    fn getId(context: *anyopaque) []const u8 {
        _ = context;
        return "test.overlay";
    }

    fn getPosition(context: *anyopaque) editorBrowser.OverlayWidgetPositionPreference {
        _ = context;
        return .top_right_corner;
    }

    fn width(context: *anyopaque, cols: usize) usize {
        _ = context;
        return @min(cols, 6);
    }

    fn height(context: *anyopaque) usize {
        _ = context;
        return 1;
    }

    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *TestOverlay = @ptrCast(@alignCast(context));
        const node = try doc.createElement(.div);
        node.asElement().focusable = true;
        node.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .reverse = true,
        });
        _ = try node.appendChild(try doc.createText("test"));
        try node.addEventListener(.{ .context = self, .key_down = onKey });
        self.node = node;
        return node;
    }

    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *TestOverlay = @ptrCast(@alignCast(context));
        return self.node;
    }

    fn isFocused(context: *anyopaque) bool {
        const self: *TestOverlay = @ptrCast(@alignCast(context));
        return self.focused;
    }

    fn onKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
        const self: *TestOverlay = @ptrCast(@alignCast(context orelse return));
        self.keys += 1;
        event.stopPropagation();
        event.preventDefault();
    }
};

test "View: overlay widget is placed top-right and takes focused keys" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var overlay = TestOverlay{};
    try view.addOverlayWidget(overlay.overlay());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const row = try rowText(view, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "test") != null);

    var event = ui.KeyEvent{ .key = .{ .char = 'x' } };
    try std.testing.expect(!view.dispatchKey(&event));

    overlay.focused = true;
    try view.refresh();
    try std.testing.expect(view.surface.document().activeElement() != null);
    try std.testing.expect(view.dispatchKey(&event));
    try std.testing.expectEqual(@as(usize, 1), overlay.keys);
}

const TestContentWidget = struct {
    position: Position,
    preference: editorBrowser.ContentWidgetPositionPreference = .below,
    width_cells: usize = 5,
    height_cells: usize = 1,
    node: ?*ui.Node = null,

    fn widget(self: *TestContentWidget) editorBrowser.IContentWidget {
        return .{
            .context = self,
            .get_id = getId,
            .get_position = getPosition,
            .width = width,
            .height = height,
            .build = build,
            .focus_node = focusNode,
            .is_focused = isFocused,
        };
    }

    fn getId(_: *anyopaque) []const u8 {
        return "test.content";
    }

    fn getPosition(context: *anyopaque) ?editorBrowser.IContentWidgetPosition {
        const self: *TestContentWidget = @ptrCast(@alignCast(context));
        return .{ .position = self.position, .preference = self.preference };
    }

    fn width(context: *anyopaque, cols: usize) usize {
        const self: *TestContentWidget = @ptrCast(@alignCast(context));
        return @min(self.width_cells, cols);
    }

    fn height(context: *anyopaque) usize {
        const self: *TestContentWidget = @ptrCast(@alignCast(context));
        return self.height_cells;
    }

    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *TestContentWidget = @ptrCast(@alignCast(context));
        const node = try doc.createElement(.div);
        node.asElement().focusable = true;
        node.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .reverse = true,
        });
        _ = try node.appendChild(try doc.createText("HOVER"));
        self.node = node;
        return node;
    }

    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *TestContentWidget = @ptrCast(@alignCast(context));
        return self.node;
    }

    fn isFocused(_: *anyopaque) bool {
        return false;
    }
};

test "View: content widget anchors to a model position" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abcdef", "test.txt", 20, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var widget = TestContentWidget{
        .position = Position.init(1, 3),
        .width_cells = 7,
        .height_cells = 1,
    };
    try view.addContentWidget(widget.widget());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    try std.testing.expectEqual(@as(usize, 1), view.terminal_view_host.viewRef().contentWidgets().entries.items.len);
    const entry = view.terminal_view_host.viewRef().contentWidgets().entries.items[0];
    // Column 3 starts at the second cell of the text area.
    try std.testing.expectEqual(editor.gutterWidth() + 2, entry.left);
    try std.testing.expectEqual(@as(usize, 1), entry.top);

    const row = try rowText(view, allocator, 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "HOVER") != null);

    const target = try view.mouseTargetAt(entry.left + 1, entry.top);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.content_widget, target.type);
}

test "View: content widget anchors on a wrapped line" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "aaaa bbbb cccc dddd", "test.txt", 23, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    // Text width is 17; the word wrap puts `dddd` on the second view line.
    try std.testing.expectEqual(@as(usize, 1), view.visibleRowOf(Position.init(1, 18)).?);
    try std.testing.expectEqual(@as(usize, 0), view.visibleRowOf(Position.init(1, 1)).?);

    var widget = TestContentWidget{
        .position = Position.init(1, 18),
        .width_cells = 5,
        .height_cells = 1,
    };
    try view.addContentWidget(widget.widget());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    try std.testing.expectEqual(@as(usize, 2), view.terminal_view_host.viewRef().contentWidgets().entries.items[0].top);
    // Column 18 is the third cell of the wrapped segment.
    try std.testing.expectEqual(editor.gutterWidth() + 2, view.terminal_view_host.viewRef().contentWidgets().entries.items[0].left);
}

test "View: content widget flips above and clamps to the text area" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb\nc", "test.txt", 12, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var below = TestContentWidget{
        .position = Position.init(2, 1),
        .preference = .below,
        .width_cells = 5,
        .height_cells = 2,
    };
    try view.addContentWidget(below.widget());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    // Row 1 is the anchor; two rows below do not fit the three-row text area,
    // so the widget is clamped to its last two rows.
    try std.testing.expectEqual(@as(usize, 1), view.terminal_view_host.viewRef().contentWidgets().entries.items[0].top);

    below.preference = .above;
    try view.refresh();
    try view.renderAnsi(&out.writer);
    try std.testing.expectEqual(@as(usize, 0), view.terminal_view_host.viewRef().contentWidgets().entries.items[0].top);
}

test "View: bracket colorization paints nesting levels" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "{ [ ] }\nplain", "test.zig", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(2, 1));

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const level0 = dark_bracket_highlight_colors[0];
    const level1 = dark_bracket_highlight_colors[1];
    const open_brace = ui.cell.unpackColor(grid.fg[grid.index(gutter, 0)]);
    try std.testing.expectEqual(level0[0], open_brace.r);
    try std.testing.expectEqual(level0[1], open_brace.g);
    try std.testing.expectEqual(level0[2], open_brace.b);
    const open_bracket = ui.cell.unpackColor(grid.fg[grid.index(gutter + 2, 0)]);
    try std.testing.expectEqual(level1[0], open_bracket.r);
    try std.testing.expectEqual(level1[1], open_bracket.g);
    try std.testing.expectEqual(level1[2], open_bracket.b);
    const close_bracket = ui.cell.unpackColor(grid.fg[grid.index(gutter + 4, 0)]);
    try std.testing.expectEqual(level1[0], close_bracket.r);
    const close_brace = ui.cell.unpackColor(grid.fg[grid.index(gutter + 6, 0)]);
    try std.testing.expectEqual(level0[0], close_brace.r);
}

test "View: unexpected closing bracket paints red" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "}\nplain", "test.zig", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(2, 1));

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const closed = ui.cell.unpackColor(grid.fg[grid.index(gutter, 0)]);
    try std.testing.expectEqual(dark_unexpected_bracket_color[0], closed.r);
    try std.testing.expectEqual(dark_unexpected_bracket_color[1], closed.g);
    try std.testing.expectEqual(dark_unexpected_bracket_color[2], closed.b);
}

test "View: bracket match keeps the colorized foreground" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "{ x }", "test.zig", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    // The bracket-match decoration adds a background, but the upstream
    // `.bracket-match` rule never overrides the colorization foreground.
    try std.testing.expect(grid.bg[grid.index(gutter, 0)] != 0);
    const bracket = ui.cell.unpackColor(grid.fg[grid.index(gutter, 0)]);
    try std.testing.expectEqual(dark_bracket_highlight_colors[0][0], bracket.r);
    try std.testing.expectEqual(dark_bracket_highlight_colors[0][1], bracket.g);
    try std.testing.expectEqual(dark_bracket_highlight_colors[0][2], bracket.b);
}

test "View: bracket colorization respects theme colors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "{ x }\nplain", "test.zig", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(2, 1));

    const color_utils = @import("../vs/platform/theme/common/colorUtils.zig");
    const color_theme = @import("../vs/workbench/services/themes/common/colorThemeData.zig");
    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    const theme = try color_theme.ColorThemeData.createUnloadedTheme(allocator, &registry, "test-dark", &.{
        .{ "editor.background", "#101010" },
        .{ "editorBracketHighlight.foreground1", "#010203" },
    });
    defer theme.deinit();
    const palette = theme_colors_mod.ThemeColors.init(theme);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    view.setThemeColors(&palette);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const open_brace = ui.cell.unpackColor(grid.fg[grid.index(gutter, 0)]);
    try std.testing.expectEqual(@as(u8, 1), open_brace.r);
    try std.testing.expectEqual(@as(u8, 2), open_brace.g);
    try std.testing.expectEqual(@as(u8, 3), open_brace.b);
}

test "View: disabling bracket colorization leaves token colors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "{ x }\nplain", "test.zig", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(2, 1));
    editor.model.updateOptions(.{
        .tabSize = null,
        .indentSize = null,
        .insertSpaces = null,
        .trimAutoWhitespace = null,
        .bracketColorizationOptions = .{ .enabled = false, .independentColorPoolPerBracketType = false },
    });

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const open_brace = ui.cell.unpackColor(grid.fg[grid.index(gutter, 0)]);
    try std.testing.expect(!(open_brace.r == 255 and open_brace.g == 215 and open_brace.b == 0));
}

test "View: strings are not bracket-colorized after eager tokenization" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "\"{\"\n{\n}\nplain", "test.zig", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(4, 1));

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const in_string = ui.cell.unpackColor(grid.fg[grid.index(gutter + 1, 0)]);
    try std.testing.expect(!(in_string.r == 255 and in_string.g == 215 and in_string.b == 0));
    const opening = ui.cell.unpackColor(grid.fg[grid.index(gutter, 1)]);
    try std.testing.expectEqual(@as(u8, 255), opening.r);
    try std.testing.expectEqual(@as(u8, 215), opening.g);
    try std.testing.expectEqual(@as(u8, 0), opening.b);
}

test "View: word highlight decorations paint text and strong colors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "word word", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setWordHighlights(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 1, 1, 5), .kind = .word_highlight_text },
        .{ .range = Range.init(1, 6, 1, 10), .kind = .word_highlight_strong },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const text = ui.cell.unpackColor(grid.bg[grid.index(gutter, 0)]);
    try std.testing.expectEqual(@as(u8, 71), text.r);
    try std.testing.expectEqual(@as(u8, 71), text.g);
    const strong = ui.cell.unpackColor(grid.bg[grid.index(gutter + 5, 0)]);
    try std.testing.expectEqual(@as(u8, 8), strong.r);
    try std.testing.expectEqual(@as(u8, 61), strong.g);
    try std.testing.expectEqual(@as(u8, 91), strong.b);
}

test "View: hover highlight paints the anchor range" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abcdef", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setHoverDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 2, 1, 5), .kind = .hover_highlight },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    // Columns 2..4 of the text are highlighted.
    const background = grid.bg[grid.index(editor.gutterWidth() + 1, 0)];
    try std.testing.expect(background != 0);
}

test "View: guides from folded hidden lines do not overwrite text" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "pub const Description = struct {\n    label: []u8,\n    description: []u8,\n\n    pub fn deinit(self: Description, allocator: Allocator) void {\n        allocator.free(self.label);\n    }\n};\n",
        "test.zig",
        50,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();

    try editor.setCursorPosition(Position.init(1, 1));
    try editor.foldAtCursor();
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const row = try rowText(view, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "│") == null);
    try std.testing.expect(std.mem.indexOf(u8, row, "pub const Description") != null);
}

test "View: gutter fold control collapses and expands a region" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "class A {\n  void f() {\n    x();\n  }\n}",
        "test.zig",
        40,
        8,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();
    // Folding is computed by the debounced pass in the running workbench;
    // the test wants the markers on its first frame.
    editor.refreshFoldingIfDirty();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '▾'), grid.cluster[grid.index(gutter - 1, 0)]);
    const target = try view.mouseTargetAt(gutter - 1, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.gutter_line_decorations, target.type);

    var down = testMouse(.down, gutter - 1, 0);
    try std.testing.expect(try view.dispatchMouse(&down));
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());
    try std.testing.expectEqual(@as(usize, 5), editor.modelLineNumber(2));

    try view.renderAnsi(&out.writer);
    try std.testing.expectEqual(@as(u32, '▸'), grid.cluster[grid.index(gutter - 1, 0)]);
    const row1 = try rowText(view, allocator, 1);
    defer allocator.free(row1);
    try std.testing.expect(std.mem.indexOf(u8, row1, "5") != null);
    // The reused rendered line must follow the new view-line mapping: row 2
    // is now model line 5, not the hidden `void f()` line.
    try std.testing.expect(std.mem.indexOf(u8, row1, "void f") == null);
    try std.testing.expect(std.mem.indexOf(u8, row1, "}") != null);

    var up = testMouse(.up, gutter - 1, 0);
    _ = try view.dispatchMouse(&up);
    var down_again = testMouse(.down, gutter - 1, 0);
    try std.testing.expect(try view.dispatchMouse(&down_again));
    try std.testing.expectEqual(@as(usize, 5), editor.viewLineCount());
    try view.renderAnsi(&out.writer);
    const unfolded_row1 = try rowText(view, allocator, 1);
    defer allocator.free(unfolded_row1);
    try std.testing.expect(std.mem.indexOf(u8, unfolded_row1, "void f") != null);
}

test "View: folding keeps a scrolled viewport at the same model line" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "pub const A = struct {\n    x: u8,\n};\npub const B = struct {\n    y: u8,\n};\npub const C = struct {\n    z: u8,\n};\n",
        "test.zig",
        40,
        6,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();

    // Cursor stays on line 1 while the viewport is scrolled to line 4.
    _ = editor.setTopViewLine(4);
    try view.refresh();
    try std.testing.expectEqual(@as(usize, 4), editor.topViewLine());

    var down = testMouse(.down, editor.gutterWidth() - 1, 0);
    try std.testing.expect(try view.dispatchMouse(&down));
    try std.testing.expectEqual(@as(usize, 4), editor.topViewLine());
    try std.testing.expectEqual(@as(usize, 4), editor.modelLineNumber(editor.topViewLine()));
}

test "View: mouse target distinguishes text, empty area, gutter and status" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc", "test.txt", 23, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const on_text = try view.mouseTargetAt(editor.gutterWidth() + 1, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.content_text, on_text.type);
    try std.testing.expectEqual(@as(usize, 2), on_text.position.?.column);

    const empty = try view.mouseTargetAt(15, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.content_empty, empty.type);
    const empty_detail = empty.detail.?.content_empty;
    try std.testing.expect(!empty_detail.is_after_lines);

    const after_lines = try view.mouseTargetAt(editor.gutterWidth(), 3);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.content_empty, after_lines.type);
    try std.testing.expect(after_lines.detail.?.content_empty.is_after_lines);

    const gutter = try view.mouseTargetAt(0, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.gutter_line_numbers, gutter.type);

    const status = try view.mouseTargetAt(3, 4);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.status, status.type);
}

test "View: the gutter keeps a blank cell before the text" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    // Number column: right-aligned in `gutter - 1`; the last gutter cell is the
    // decorations/gap column; text starts at `gutter`.
    try std.testing.expectEqual(@as(u32, '1'), grid.cluster[grid.index(gutter - 2, 0)]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(gutter - 1, 0)]);
    try std.testing.expectEqual(@as(u32, 'a'), grid.cluster[grid.index(gutter, 0)]);
}

test "View: scrolling reuses the visible line DOM nodes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..50) |line| {
        var buffer: [32]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&buffer, "line {d}\n", .{line + 1});
        try text.appendSlice(allocator, formatted);
    }
    const editor = try Editor.createFromText(allocator, io, text.items, "test.txt", 30, 10);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const view_lines = view.terminal_view_host.viewRef().getViewLines();
    const first_window_start = view_lines.windowStart();
    const retained_number = first_window_start + 2;
    const retained = view_lines.lineAt(retained_number);
    const node_before = retained.dom_node orelse return error.TestUnexpectedResult;
    const text_before = node_before.first_child orelse return error.TestUnexpectedResult;
    const box_before = view.surface.box_tree.find(node_before) orelse return error.TestUnexpectedResult;
    const box_y_before = box_before.rect.y;
    // Equal token styles share one interned PaintStyle object (the CSS-class
    // analogue) rather than carrying a full Style per run.
    const neighbor = view_lines.lineAt(retained_number + 1).dom_node orelse return error.TestUnexpectedResult;
    const neighbor_run = neighbor.first_child orelse return error.TestUnexpectedResult;
    try std.testing.expect(text_before.paintStyle().? == neighbor_run.paintStyle().?);

    try std.testing.expect(editor.scrollViewLines(1));
    try view.refresh();
    try view.paint();

    try std.testing.expectEqual(first_window_start + 1, view_lines.windowStart());
    try std.testing.expectEqual(node_before, view_lines.lineAt(retained_number).dom_node.?);
    try std.testing.expectEqual(text_before, node_before.first_child.?);
    // The retained line's box is moved, not rebuilt or re-laid-out.
    try std.testing.expectEqual(box_before, view.surface.box_tree.find(node_before).?);
    try std.testing.expectEqual(box_y_before - 1, box_before.rect.y);

    const perf = view.perfCounters();
    try std.testing.expectEqual(@as(usize, 1), perf.full_box_solves);
    try std.testing.expectEqual(@as(usize, 1), perf.line_added);
    try std.testing.expectEqual(@as(usize, 0), perf.line_rebuilt);
    try std.testing.expectEqual(
        view_lines.windowEnd() - view_lines.windowStart(),
        perf.line_translated,
    );

    // The UI scroll view's content node holds exactly the windowed line nodes:
    // the leaving line was unlinked and the entering line got a node, so the
    // DOM count stays at the viewport size instead of growing with the document.
    const content_root = view.line_scroll.contentNode();
    var child_count: usize = 0;
    var child = content_root.first_child;
    while (child) |current| : (child = current.next) child_count += 1;
    try std.testing.expectEqual(view_lines.windowEnd() - view_lines.windowStart() + 1, child_count);
    try std.testing.expect(view_lines.lineAt(view_lines.windowEnd()).dom_node != null);
}

fn testMouse(kind: ui.MouseKind, x: usize, y: usize) ui.MouseEvent {
    return .{ .kind = kind, .x = x, .y = y, .button = .left };
}

test "View: a left click places the caret and ignores gutter and status" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc\ndef", "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const gutter = editor.gutterWidth();
    var down = testMouse(.down, gutter + 1, 1);
    try std.testing.expect(try view.dispatchMouse(&down));
    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().column);

    // The status row and the gutter are not text.
    try editor.setCursorPosition(Position.init(1, 2));
    var gutter_click = testMouse(.down, gutter -| 1, 0);
    try std.testing.expect(!try view.dispatchMouse(&gutter_click));
    try std.testing.expectEqual(@as(usize, 1), editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().column);

    var status_click = testMouse(.down, gutter, 5);
    try std.testing.expect(!try view.dispatchMouse(&status_click));
    try std.testing.expectEqual(@as(usize, 1), editor.modelCursorPosition().lineNumber);

    // Past the end of the line clamps to its last column.
    var past_end = testMouse(.down, gutter + 20, 0);
    try std.testing.expect(try view.dispatchMouse(&past_end));
    try std.testing.expectEqual(@as(usize, 4), editor.modelCursorPosition().column);
}

test "View: clicks account for tabs, wide characters and wrapped lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "ab\tcd\na何b", "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();
    const gutter = editor.gutterWidth();

    // ab -> cells 0-1, tab -> 2-3, c -> 4, d -> 5.
    var tab_click = testMouse(.down, gutter + 4, 0);
    try std.testing.expect(try view.dispatchMouse(&tab_click));
    try std.testing.expectEqual(@as(usize, 4), editor.modelCursorPosition().column);

    // a -> cell 0, 何 -> cells 1-2, b -> cell 3.
    var wide_click = testMouse(.down, gutter + 3, 1);
    try std.testing.expect(try view.dispatchMouse(&wide_click));
    try std.testing.expectEqual(@as(usize, 5), editor.modelCursorPosition().column);
}

test "View: a click on a wrapped continuation maps to its model line" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 8, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();
    try std.testing.expect(editor.viewLineCount() > 1);

    const expected = try editor.positionAtViewPoint(2, 0);
    var click = testMouse(.down, editor.gutterWidth(), 1);
    try std.testing.expect(try view.dispatchMouse(&click));
    try std.testing.expectEqual(expected.lineNumber, editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(expected.column, editor.modelCursorPosition().column);
}

test "View: shift-click extends and a drag selects without clicking" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "hello world", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();
    const gutter = editor.gutterWidth();

    var first = testMouse(.down, gutter, 0);
    _ = try view.dispatchMouse(&first);
    var extend = testMouse(.down, gutter + 3, 0);
    extend.mods.shift = true;
    try std.testing.expect(try view.dispatchMouse(&extend));
    const extended = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 1), extended.selectionStartColumn);
    try std.testing.expectEqual(@as(usize, 4), extended.positionColumn);

    const ClickLog = struct {
        count: usize = 0,

        fn onClick(context: ?*anyopaque, _: *ui.MouseEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.count += 1;
        }
    };
    var clicks = ClickLog{};
    try view.surface.document().root.?.addEventListener(.{
        .context = &clicks,
        .click = ClickLog.onClick,
    });

    var down = testMouse(.down, gutter, 0);
    _ = try view.dispatchMouse(&down);
    var move = testMouse(.move, gutter + 4, 0);
    try std.testing.expect(try view.dispatchMouse(&move));
    const selected = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 1), selected.startColumn);
    try std.testing.expectEqual(@as(usize, 5), selected.endColumn);
    var up = testMouse(.up, gutter + 4, 0);
    try std.testing.expect(!try view.dispatchMouse(&up));
    try std.testing.expectEqual(@as(usize, 0), clicks.count);

    // A plain press and release still clicks.
    var plain_down = testMouse(.down, gutter, 0);
    _ = try view.dispatchMouse(&plain_down);
    var plain_up = testMouse(.up, gutter, 0);
    _ = try view.dispatchMouse(&plain_up);
    try std.testing.expectEqual(@as(usize, 1), clicks.count);
}

test "View: the wheel scrolls without moving the caret and clamps" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "line0\nline1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11",
        "test.txt",
        40,
        5,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 1), editor.topViewLine());

    var down = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 0, .delta_y = 3 };
    try std.testing.expect(!try view.dispatchMouse(&down));
    try std.testing.expectEqual(@as(usize, 4), editor.topViewLine());
    try std.testing.expectEqual(@as(usize, 1), editor.modelCursorPosition().lineNumber);

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);
    const row = try rowText(view, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "line3") != null);
    // The caret is off-screen, so the hardware cursor has no cell.
    try std.testing.expectEqual(@as(?Cell, null), view.cursorCell());

    // The status row does not scroll.
    var status = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 4, .delta_y = 3 };
    try std.testing.expect(!try view.dispatchMouse(&status));
    try std.testing.expectEqual(@as(usize, 4), editor.topViewLine());

    var up = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 0, .delta_y = -3 };
    _ = try view.dispatchMouse(&up);
    try std.testing.expectEqual(@as(usize, 1), editor.topViewLine());

    var end = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 0, .delta_y = 100 };
    _ = try view.dispatchMouse(&end);
    const max_top = editor.viewLineCount() - editor.textHeight() + 1;
    try std.testing.expectEqual(max_top, editor.topViewLine());

    // The next cursor move reveals the caret again.
    try editor.moveDown(false);
    try std.testing.expect(editor.topViewLine() <= editor.modelCursorPosition().lineNumber);
}

test "View: matching brackets are highlighted while the cursor is on one" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "(a)\n(\n)\nx", "test.zig", 20, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    try editor.setCursorPosition(Position.init(1, 2));
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const bracket_bg = ui.cell.packColor(color(bracket_match_background));
    var grid = view.surface.grid();
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter, 0)]);
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter + 2, 0)]);

    // Cursor off any bracket clears the highlights.
    try editor.setCursorPosition(Position.init(4, 1));
    try view.refresh();
    try view.renderAnsi(&out.writer);
    grid = view.surface.grid();
    try std.testing.expect(grid.bg[grid.index(gutter, 0)] != bracket_bg);
    try std.testing.expect(grid.bg[grid.index(gutter + 2, 0)] != bracket_bg);

    // A pair spanning lines highlights both brackets.
    try editor.setCursorPosition(Position.init(2, 2));
    try view.refresh();
    try view.renderAnsi(&out.writer);
    grid = view.surface.grid();
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter, 1)]);
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter, 2)]);
}

test "View: a focused widget hides bracket highlights" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "(a)", "test.zig", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(1, 2));

    var overlay = TestOverlay{ .focused = true };
    try view.addOverlayWidget(overlay.overlay());
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);
    const gutter = editor.gutterWidth();
    const bracket_bg = ui.cell.packColor(color(bracket_match_background));
    const grid = view.surface.grid();
    try std.testing.expect(grid.bg[grid.index(gutter, 0)] != bracket_bg);
}

test "View: typing an auto-closed bracket highlights the pair" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "", "test.zig", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    try editor.typeCharacter("(");
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const bracket_bg = ui.cell.packColor(color(bracket_match_background));
    const grid = view.surface.grid();
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter, 0)]);
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter + 1, 0)]);
}

test "View: bracket highlights stay on their wrapped segment" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "(abcdefghij)", "test.zig", 13, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expect(editor.viewLineCount() > 1);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(1, 2));
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const bracket_bg = ui.cell.packColor(color(bracket_match_background));
    const grid = view.surface.grid();
    // The opening bracket is on the first segment.
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter, 0)]);
    // The last continuation is "j)"; its closing bracket is one cell in.
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter + 1, 2)]);
    // Previous continuations must not get a mis-mapped cell at their start.
    try std.testing.expect(grid.bg[grid.index(gutter, 1)] != bracket_bg);
    try std.testing.expect(grid.bg[grid.index(gutter, 2)] != bracket_bg);
}

test "View: find decorations stay on their wrapped segment" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 14, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expect(editor.viewLineCount() > 1);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 7, 1, 11), .kind = .find_match },
    });
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const match_bg = ui.cell.packColor(color(find_match_background));
    const grid = view.surface.grid();
    // "ghij" is the whole second segment: cells 0..3.
    var cell: usize = 0;
    while (cell < 4) : (cell += 1) {
        try std.testing.expectEqual(match_bg, grid.bg[grid.index(gutter + cell, 1)]);
    }
    try std.testing.expect(grid.bg[grid.index(gutter + 4, 1)] != match_bg);
    cell = 0;
    while (cell < 5) : (cell += 1) {
        try std.testing.expect(grid.bg[grid.index(gutter + cell, 0)] != match_bg);
    }
}

test "View: bracket highlights include the synthetic wrap indentation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "    (abcdefghij)", "test.zig", 14, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expect(editor.viewLineCount() > 1);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(1, 6));
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const cols = view.surface.document().cols;
    const rows = editor.textHeight();
    const bracket_bg = ui.cell.packColor(color(bracket_match_background));
    const grid = view.surface.grid();

    var found_open = false;
    var found_close = false;
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var col = gutter;
        while (col < cols) : (col += 1) {
            const cluster = grid.cluster[grid.index(col, row)];
            if (cluster == '(') {
                found_open = true;
                try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(col, row)]);
            } else if (cluster == ')') {
                found_close = true;
                try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(col, row)]);
            }
        }
    }
    try std.testing.expect(found_open);
    try std.testing.expect(found_close);

    // Synthetic indentation cells are not bracket cells.
    row = 1;
    while (row < rows) : (row += 1) {
        try std.testing.expect(grid.bg[grid.index(gutter, row)] != bracket_bg);
    }
}

test "View: right column paints markers and the overlapping thumb" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try numberedLines(allocator, 20);
    defer allocator.free(text);
    const editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(8, 1));
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 1, 1, 2), .kind = .find_match },
        .{ .range = Range.init(10, 1, 10, 2), .kind = .find_match },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const cols = view.surface.document().cols;
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(usize, 2), view.scrollbar_width);
    const marker_col = cols - 2;
    const thumb_col = cols - 1;
    try std.testing.expectEqual(marker_col, editor.textAreaRight());

    const find_fg = ui.cell.packColor(color(overview_find_color));
    const thumb_fg = ui.cell.packColor(color(scrollbar_thumb_color));

    // Twenty lines in a seven-row track need a 2.45-cell thumb. The cursor
    // scrolls the viewport, so the exact thumb starts at the lower half of row
    // 0 and ends at the row 2 boundary; half-cell glyphs render both edges.
    try std.testing.expectEqual(@as(u32, '▗'), grid.cluster[grid.index(marker_col, 0)]);
    try std.testing.expectEqual(@as(u32, '▄'), grid.cluster[grid.index(thumb_col, 0)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(marker_col, 0)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(thumb_col, 0)]);
    try std.testing.expectEqual(@as(u32, '▐'), grid.cluster[grid.index(marker_col, 1)]);
    try std.testing.expectEqual(@as(u32, '█'), grid.cluster[grid.index(thumb_col, 1)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(marker_col, 1)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(thumb_col, 1)]);
    try std.testing.expectEqual(@as(u32, '▐'), grid.cluster[grid.index(marker_col, 2)]);
    try std.testing.expectEqual(@as(u32, '█'), grid.cluster[grid.index(thumb_col, 2)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(marker_col, 2)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(thumb_col, 2)]);
    // The second find spans the lower half of row 2 (covered by the thumb) and
    // the upper half of row 3, so its left lane is the upper-right quadrant of
    // the first cell.
    try std.testing.expectEqual(@as(u32, '▝'), grid.cluster[grid.index(marker_col, 3)]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(thumb_col, 3)]);
    try std.testing.expectEqual(find_fg, grid.fg[grid.index(marker_col, 3)]);

    // The shared area is two cells wide: the cell immediately to its left is
    // the end of the text area, not another scrollbar column. A background
    // fill (for example the scroll shadow) may materialize trailing cells as
    // spaces, so accept either an empty or a blank cell.
    try std.testing.expect(grid.cluster[grid.index(marker_col - 1, 0)] == 0 or
        grid.cluster[grid.index(marker_col - 1, 0)] == ' ');
    try std.testing.expect(grid.cluster[grid.index(marker_col - 1, 3)] == 0 or
        grid.cluster[grid.index(marker_col - 1, 3)] == ' ');
}

test "View: short document has no scrollbar thumb" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 20, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(2, 1, 2, 2), .kind = .find_match },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const cols = view.surface.document().cols;
    const grid = view.surface.grid();
    const marker_col = cols - 2;
    const thumb_col = cols - 1;
    const find_fg = ui.cell.packColor(color(overview_find_color));

    // Line 2 maps below the cursor row but no thumb is needed. Find uses the
    // first lane, so only the first cell's right half is filled.
    try std.testing.expectEqual(@as(u32, '▐'), grid.cluster[grid.index(marker_col, 1)]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(thumb_col, 1)]);
    try std.testing.expectEqual(find_fg, grid.fg[grid.index(marker_col, 1)]);
    const thumb_fg = ui.cell.packColor(color(scrollbar_thumb_color));
    var row: usize = 0;
    while (row < editor.textHeight()) : (row += 1) {
        try std.testing.expect(grid.fg[grid.index(marker_col, row)] != thumb_fg);
        try std.testing.expect(grid.fg[grid.index(thumb_col, row)] != thumb_fg);
    }
}

test "View: mouse target distinguishes overview ruler and scrollbar" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try numberedLines(allocator, 20);
    defer allocator.free(text);
    const editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    const cols = view.surface.document().cols;

    const scrollbar = try view.mouseTargetAt(cols - 1, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.scrollbar, scrollbar.type);
    const ruler = try view.mouseTargetAt(cols - 2, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.scrollbar, ruler.type);

    const caret_before = editor.modelCursorPosition();
    var down = testMouse(.down, cols - 1, 4);
    try std.testing.expect(!try view.dispatchMouse(&down));
    var up = testMouse(.up, cols - 1, 4);
    try std.testing.expect(!try view.dispatchMouse(&up));
    try std.testing.expect(editor.topViewLine() > 1);
    try std.testing.expectEqual(caret_before.lineNumber, editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(caret_before.column, editor.modelCursorPosition().column);

    // Dragging the thumb maps row deltas through ScrollbarState.
    try std.testing.expect(editor.setTopViewLine(1));
    try view.refresh();
    var press = testMouse(.down, cols - 1, 0);
    try std.testing.expect(!try view.dispatchMouse(&press));
    var drag = testMouse(.move, cols - 1, 4);
    try std.testing.expect(!try view.dispatchMouse(&drag));
    var release = testMouse(.up, cols - 1, 4);
    try std.testing.expect(!try view.dispatchMouse(&release));
    try std.testing.expect(editor.topViewLine() > 1);
    try std.testing.expectEqual(caret_before.lineNumber, editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(caret_before.column, editor.modelCursorPosition().column);
}

test "View: narrow terminal hides the scrollbar columns" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc", "test.txt", 4, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 0), view.scrollbar_width);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const cols = view.surface.document().cols;
    const target = try view.mouseTargetAt(cols - 1, 0);
    try std.testing.expect(target.type != .scrollbar);

    const grid = view.surface.grid();
    var row: usize = 0;
    while (row < editor.textHeight()) : (row += 1) {
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            try std.testing.expect(grid.cluster[grid.index(col, row)] != '█');
        }
    }
}

test "View: overview markers honor the per-decoration flag" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb\nc", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var markers = std.array_list.Managed(decorationsOverviewRuler.Decoration).init(allocator);
    defer markers.deinit();
    try view.replaceModelDecorations(DecorationOwner.bracket, &[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 1, 1, 2), .kind = .bracket_match, .show_in_overview_ruler = false },
        .{ .range = Range.init(2, 1, 2, 2), .kind = .find_scope },
        .{ .range = Range.init(3, 1, 3, 2), .kind = .bracket_match },
    });
    try view.appendOverviewMarkers(&markers);
    try std.testing.expectEqual(@as(usize, 1), markers.items.len);
    try std.testing.expectEqual(@as(usize, 3), markers.items[0].start_line_number);
    try std.testing.expectEqual(overview_bracket_color, markers.items[0].color);
}

test "View: overview markers follow wrapped view lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 13, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expect(editor.viewLineCount() > 1);

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var markers = std.array_list.Managed(decorationsOverviewRuler.Decoration).init(allocator);
    defer markers.deinit();
    try view.replaceModelDecorations(DecorationOwner.find, &[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 1, 1, 2), .kind = .find_match },
        .{ .range = Range.init(1, 7, 1, 9), .kind = .find_match },
    });
    try view.appendOverviewMarkers(&markers);
    try std.testing.expectEqual(@as(usize, 2), markers.items.len);
    try std.testing.expectEqual(@as(usize, 1), markers.items[0].start_line_number);
    try std.testing.expectEqual(@as(usize, 2), markers.items[1].start_line_number);
}

test "View: three overview lanes use half-cell glyphs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb\nc\nd", "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(1, 1));
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(2, 1, 2, 2), .kind = .find_match },
        .{ .range = Range.init(3, 1, 3, 2), .kind = .bracket_match },
        .{ .range = Range.init(4, 1, 4, 2), .kind = .word_highlight },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const cols = view.surface.document().cols;
    const grid = view.surface.grid();
    const first = cols - 2;
    const second = cols - 1;

    // Cursor: half-height upper edge across the full 1.5-cell width.
    try std.testing.expectEqual(@as(u32, '▝'), grid.cluster[grid.index(first, 0)]);
    try std.testing.expectEqual(@as(u32, '▀'), grid.cluster[grid.index(second, 0)]);
    // Find: left lane, right half of the first cell.
    try std.testing.expectEqual(@as(u32, '▐'), grid.cluster[grid.index(first, 1)]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(second, 1)]);
    // Bracket: right lane, right half of the second cell.
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(first, 2)]);
    try std.testing.expectEqual(@as(u32, '▐'), grid.cluster[grid.index(second, 2)]);
    // Word: center lane, left half of the second cell.
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(first, 3)]);
    try std.testing.expectEqual(@as(u32, '▌'), grid.cluster[grid.index(second, 3)]);
}

test "View: half-cell thumb uses quadrant edges" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try numberedLines(allocator, 13);
    defer allocator.free(text);
    const editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try std.testing.expect(editor.setTopViewLine(2));
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const cols = view.surface.document().cols;
    const grid = view.surface.grid();
    const first = cols - 2;
    const second = cols - 1;

    // The exact thumb is 25/13 cells tall and starts at half a cell; both
    // edges quantize to half cells, so the lower half of row 0, all of row 1
    // and the upper half of row 2 are painted.
    try std.testing.expectEqual(@as(u32, '▗'), grid.cluster[grid.index(first, 0)]);
    try std.testing.expectEqual(@as(u32, '▄'), grid.cluster[grid.index(second, 0)]);
    try std.testing.expectEqual(@as(u32, '▐'), grid.cluster[grid.index(first, 1)]);
    try std.testing.expectEqual(@as(u32, '█'), grid.cluster[grid.index(second, 1)]);
    try std.testing.expectEqual(@as(u32, '▝'), grid.cluster[grid.index(first, 2)]);
    try std.testing.expectEqual(@as(u32, '▀'), grid.cluster[grid.index(second, 2)]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(first, 3)]);
}

test "View: half-cell markers use quadrant glyphs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try numberedLines(allocator, 13);
    defer allocator.free(text);
    const editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(8, 1, 10, 2), .kind = .word_highlight },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const cols = view.surface.document().cols;
    const grid = view.surface.grid();
    const first = cols - 2;
    const second = cols - 1;
    const word_fg = ui.cell.packColor(color(overview_word_color));

    // Lines 8-10 project to half-cells 5..7: the lower half of row 2 and the
    // upper half of row 3. The center lane uses the left quadrants of the
    // second cell.
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(first, 2)]);
    try std.testing.expectEqual(@as(u32, '▖'), grid.cluster[grid.index(second, 2)]);
    try std.testing.expectEqual(word_fg, grid.fg[grid.index(second, 2)]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(first, 3)]);
    try std.testing.expectEqual(@as(u32, '▘'), grid.cluster[grid.index(second, 3)]);
    try std.testing.expectEqual(word_fg, grid.fg[grid.index(second, 3)]);
}

test "View: single-line center marker uses one half-cell" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try numberedLines(allocator, 13);
    defer allocator.free(text);
    const editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(11, 1, 11, 2), .kind = .word_highlight },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const cols = view.surface.document().cols;
    const grid = view.surface.grid();
    const word_fg = ui.cell.packColor(color(overview_word_color));

    // Line 11 projects to half-cell 7, so the center lane is one half-cell
    // tall instead of expanding to a full row.
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(cols - 2, 3)]);
    try std.testing.expectEqual(@as(u32, '▖'), grid.cluster[grid.index(cols - 1, 3)]);
    try std.testing.expectEqual(word_fg, grid.fg[grid.index(cols - 1, 3)]);
}

test "View: indent guides mark leading whitespace and blank lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "if x:\n" ++
        "    if y:\n" ++
        "        z()\n" ++
        "\n" ++
        "        w()\n" ++
        "    end\n" ++
        "end";
    const editor = try Editor.createFromText(allocator, io, text, "test.zig", 40, 9);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    const guide_fg = ui.cell.packColor(color(indent_guide_color));
    const active_fg = ui.cell.packColor(color(indent_guide_active_color));

    // Level 1 on the first indented line. The caret is on the unindented first
    // line, which upstream treats as the start of the indented scope, so this
    // guide is the active scope.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 1)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 1)]);

    // Level 2 adds a normal guide at the next indentation column; the active
    // level-1 scope continues through the whole indented block.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 2)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 2)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter + 4, 2)]);
    try std.testing.expectEqual(guide_fg, grid.fg[grid.index(gutter + 4, 2)]);

    // The blank line inherits both guides from the surrounding block.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 3)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter + 4, 3)]);
    try std.testing.expectEqual(guide_fg, grid.fg[grid.index(gutter + 4, 3)]);

    // The unindented first and last lines have no guides.
    try std.testing.expectEqual(@as(u32, 'i'), grid.cluster[grid.index(gutter, 0)]);
    try std.testing.expectEqual(@as(u32, 'e'), grid.cluster[grid.index(gutter, 6)]);
}

test "View: rendered whitespace uses one theme color and guides paint over it" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "fn  a  b\n" ++
        "    child\n" ++
        "        grand\n";
    const editor = try Editor.createFromText(allocator, io, text, "test.zig", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const color_utils = @import("../vs/platform/theme/common/colorUtils.zig");
    const color_theme = @import("../vs/workbench/services/themes/common/colorThemeData.zig");
    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    const theme = try color_theme.ColorThemeData.createUnloadedTheme(allocator, &registry, "test-dark", &.{
        .{ "editor.background", "#101010" },
        .{ "editorWhitespace.foreground", "#00ff00" },
        .{ "editorIndentGuide.background1", "#ff0000" },
        .{ "editorIndentGuide.activeBackground1", "#ff0000" },
    });
    defer theme.deinit();
    const palette = theme_colors_mod.ThemeColors.init(theme);
    view.setThemeColors(&palette);

    view.terminal_view_host.options.set(.renderWhitespace, .all);
    const option_count = @typeInfo(editor_options.EditorOption).@"enum".field_names.len;
    var changed: [option_count]bool = @splat(false);
    changed[@backingInt(editor_options.EditorOption.renderWhitespace)] = true;
    const event = view_events.ViewConfigurationChangedEvent.init(
        editor_options.ConfigurationChangedEvent.init(&changed),
    );
    _ = view.terminal_view_host.viewRef().onConfigurationChanged(&event);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const whitespace_fg = ui.cell.packColor(.{ .r = 0, .g = 255, .b = 0 });
    const guide_fg = ui.cell.packColor(.{ .r = 255, .g = 0, .b = 0 });

    // Every rendered space is the same mid-dot, regardless of the token that
    // precedes or follows it.
    for ([_]usize{ 2, 3, 5, 6 }) |column| {
        try std.testing.expectEqual(@as(u32, 0x00B7), grid.cluster[grid.index(gutter + column, 0)]);
        try std.testing.expectEqual(whitespace_fg, grid.fg[grid.index(gutter + column, 0)]);
    }

    // The indentation guide wins the cell over the whitespace dot at both
    // nesting levels, and it keeps its own color.
    try std.testing.expectEqual(@as(u32, 0x2502), grid.cluster[grid.index(gutter, 1)]);
    try std.testing.expectEqual(guide_fg, grid.fg[grid.index(gutter, 1)]);
    try std.testing.expectEqual(@as(u32, 0x2502), grid.cluster[grid.index(gutter, 2)]);
    try std.testing.expectEqual(guide_fg, grid.fg[grid.index(gutter, 2)]);
    try std.testing.expectEqual(@as(u32, 0x2502), grid.cluster[grid.index(gutter + 4, 2)]);
    try std.testing.expectEqual(guide_fg, grid.fg[grid.index(gutter + 4, 2)]);

    // The cells between the guides are still rendered whitespace.
    for ([_]usize{ 1, 2, 3, 5, 6, 7 }) |column| {
        try std.testing.expectEqual(@as(u32, 0x00B7), grid.cluster[grid.index(gutter + column, 2)]);
        try std.testing.expectEqual(whitespace_fg, grid.fg[grid.index(gutter + column, 2)]);
    }
}

test "View: space dot and tab arrow share the whitespace color" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "\tfoo bar\n", "test.txt", 30, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const color_utils = @import("../vs/platform/theme/common/colorUtils.zig");
    const color_theme = @import("../vs/workbench/services/themes/common/colorThemeData.zig");
    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    const theme = try color_theme.ColorThemeData.createUnloadedTheme(allocator, &registry, "test-dark", &.{
        .{ "editor.background", "#101010" },
        .{ "editorWhitespace.foreground", "#00ff00" },
        .{ "editorIndentGuide.background1", "#ff0000" },
        .{ "editorIndentGuide.activeBackground1", "#ff0000" },
    });
    defer theme.deinit();
    const palette = theme_colors_mod.ThemeColors.init(theme);
    view.setThemeColors(&palette);

    view.terminal_view_host.options.set(.renderWhitespace, .all);
    const option_count = @typeInfo(editor_options.EditorOption).@"enum".field_names.len;
    var changed: [option_count]bool = @splat(false);
    changed[@backingInt(editor_options.EditorOption.renderWhitespace)] = true;
    const event = view_events.ViewConfigurationChangedEvent.init(
        editor_options.ConfigurationChangedEvent.init(&changed),
    );
    _ = view.terminal_view_host.viewRef().onConfigurationChanged(&event);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    // The tab expands to four cells. The indent guide keeps its first cell,
    // and the repeated `→` marker lands in the tab's padding at the next
    // column. The space after `foo` is the plain `·` marker.
    const arrow_cell = grid.index(gutter + 1, 0);
    const dot_cell = grid.index(gutter + 7, 0);
    try std.testing.expectEqual(@as(u32, 0x2192), grid.cluster[arrow_cell]);
    try std.testing.expectEqual(@as(u32, 0x00B7), grid.cluster[dot_cell]);
    // Both visible-whitespace glyphs paint the same `mtkw` color: the tab
    // marker must not pick up the guide color or a token color.
    const whitespace_fg = ui.cell.packColor(.{ .r = 0, .g = 255, .b = 0 });
    try std.testing.expectEqual(whitespace_fg, grid.fg[arrow_cell]);
    try std.testing.expectEqual(whitespace_fg, grid.fg[dot_cell]);
}

test "View: rendered whitespace falls back to a dimmed foreground" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a b", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    view.terminal_view_host.options.set(.renderWhitespace, .all);
    const option_count = @typeInfo(editor_options.EditorOption).@"enum".field_names.len;
    var changed: [option_count]bool = @splat(false);
    changed[@backingInt(editor_options.EditorOption.renderWhitespace)] = true;
    const event = view_events.ViewConfigurationChangedEvent.init(
        editor_options.ConfigurationChangedEvent.init(&changed),
    );
    _ = view.terminal_view_host.viewRef().onConfigurationChanged(&event);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const cell = grid.index(gutter + 1, 0);
    try std.testing.expectEqual(@as(u32, 0x00B7), grid.cluster[cell]);

    // Themes without `editorWhitespace.foreground` get the default foreground
    // faded over the editor background so the dot is dim but readable.
    const expected = fadeOver(
        color(default_text_color),
        whitespace_fallback_alpha,
        color([3]u8{ 30, 30, 33 }),
    );
    try std.testing.expectEqual(ui.cell.packColor(expected), grid.fg[cell]);
    try std.testing.expect(ui.cell.unpackColor(grid.fg[cell]).r < default_text_color[0]);
}

test "View: selected whitespace guide keeps the selection background" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "    x", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setSelections(&[_]Selection{Selection.init(1, 1, 1, 5)});

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const guide = grid.index(gutter, 0);
    // The selected leading spaces render whitespace markers, but the guide
    // wins the shared cell. It must keep the selection background (the guide
    // text run has no background of its own) instead of dropping out of the
    // band as a dark cell, which is what the old inverse paint did.
    try std.testing.expectEqual(@as(u32, '\u{2502}'), grid.cluster[guide]);
    try std.testing.expectEqual(
        ui.cell.packColor(color(selection_background_dark)),
        grid.bg[guide],
    );
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[guide] & ui.cell.Attr.inverse);
    // The guide keeps its own foreground color rather than the terminal default.
    try std.testing.expect(grid.fg[guide] != 0);
}

test "View: selected tab renders its marker after the indent guide" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "\tfoo", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setSelections(&[_]Selection{Selection.init(1, 1, 1, 5)});

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const guide_cell = grid.index(gutter, 0);
    const arrow_cell = grid.index(gutter + 1, 0);
    const rendered = try rowText(view, allocator, 0);
    defer allocator.free(rendered);
    // The tab expands to four cells. The indent guide keeps its first cell and
    // the arrow is repeated in the next cell (one of the tab's padding cells),
    // so both stay visible while the selection is active.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{2502}\u{2192}  foo") != null);
    try std.testing.expectEqual(@as(u32, 0x2502), grid.cluster[guide_cell]);
    try std.testing.expectEqual(@as(u32, 0x2192), grid.cluster[arrow_cell]);
    try std.testing.expectEqual(
        ui.cell.packColor(color(selection_background_dark)),
        grid.bg[guide_cell],
    );
    try std.testing.expectEqual(
        ui.cell.packColor(color(selection_background_dark)),
        grid.bg[arrow_cell],
    );

    // Without a selection there is no marker: the guide stays and the padding
    // cells are blank.
    try editor.setSelections(&[_]Selection{Selection.init(1, 5, 1, 5)});
    try view.refresh();
    try view.renderAnsi(&out.writer);
    const cleared = view.surface.grid();
    try std.testing.expectEqual(@as(u32, 0x2502), cleared.cluster[guide_cell]);
    try std.testing.expectEqual(@as(u32, ' '), cleared.cluster[arrow_cell]);
}

test "View: each selected tab renders after its own indent guide" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "\t\tfoo", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setSelections(&[_]Selection{Selection.init(1, 1, 1, 3)});

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const rendered = try rowText(view, allocator, 0);
    defer allocator.free(rendered);
    // Two four-cell tabs and two indent guides: `│→  │→  foo`.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{2502}\u{2192}  \u{2502}\u{2192}  foo") != null);
    try std.testing.expectEqual(@as(u32, 0x2502), grid.cluster[grid.index(gutter, 0)]);
    try std.testing.expectEqual(@as(u32, 0x2192), grid.cluster[grid.index(gutter + 1, 0)]);
    try std.testing.expectEqual(@as(u32, 0x2502), grid.cluster[grid.index(gutter + 4, 0)]);
    try std.testing.expectEqual(@as(u32, 0x2192), grid.cluster[grid.index(gutter + 5, 0)]);
}

test "View: one-cell tab keeps its indent guide" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "\tfoo", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    // A one-cell tab has no padding cell to move the arrow into, so the guide
    // wins the shared cell and the marker is not visible.
    const Settings = struct {
        detect_indentation: std.json.Value = .{ .bool = false },
        tab_size: std.json.Value = .{ .integer = 1 },
        indent_size: std.json.Value = .{ .integer = 1 },

        fn get(context: *anyopaque, key: []const u8, _: ?[]const u8, _: ?[]const u8) ?*const std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, key, "editor.detectIndentation")) return &self.detect_indentation;
            if (std.mem.eql(u8, key, "editor.tabSize")) return &self.tab_size;
            if (std.mem.eql(u8, key, "editor.indentSize")) return &self.indent_size;
            return null;
        }
    };
    var settings = Settings{};
    _ = try editor.applyEditorSettings(.{ .context = &settings, .get_value = Settings.get }, null, null);

    try editor.setSelections(&[_]Selection{Selection.init(1, 1, 1, 5)});

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const first_cell = grid.index(gutter, 0);
    const rendered = try rowText(view, allocator, 0);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{2502}foo") != null);
    try std.testing.expectEqual(@as(u32, 0x2502), grid.cluster[first_cell]);
    try std.testing.expectEqual(
        ui.cell.packColor(color(selection_background_dark)),
        grid.bg[first_cell],
    );
}

test "View: indent guides honor per-level theme colors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "root\n" ++
        "    child\n" ++
        "        grand\n";
    const editor = try Editor.createFromText(allocator, io, text, "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const color_utils = @import("../vs/platform/theme/common/colorUtils.zig");
    const color_theme = @import("../vs/workbench/services/themes/common/colorThemeData.zig");
    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    const theme = try color_theme.ColorThemeData.createUnloadedTheme(allocator, &registry, "test-dark", &.{
        .{ "editor.background", "#101010" },
        .{ "editorIndentGuide.background1", "#ff0000" },
        .{ "editorIndentGuide.activeBackground1", "#aa0000" },
        .{ "editorIndentGuide.background2", "#00ff00" },
        .{ "editorIndentGuide.activeBackground2", "#00aa00" },
    });
    defer theme.deinit();
    const palette = theme_colors_mod.ThemeColors.init(theme);

    // The caret on `grand` makes line 3's level-2 guide the active scope;
    // line 2 keeps the normal level-1 color.
    try editor.setCursorPosition(Position.init(3, 1));
    const view = try View.init(allocator, editor);
    defer view.deinit();
    view.setThemeColors(&palette);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const level1 = grid.fg[grid.index(gutter, 1)];
    try std.testing.expectEqual(ui.cell.packColor(.{ .r = 255, .g = 0, .b = 0 }), level1);
    const level2 = grid.fg[grid.index(gutter + 4, 2)];
    try std.testing.expectEqual(ui.cell.packColor(.{ .r = 0, .g = 170, .b = 0 }), level2);
}

test "View: bracket guides follow pairs and highlight the active pair" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "fn main() {\n" ++
        "    if (x) {\n" ++
        "        y();\n" ++
        "    }\n" ++
        "}";
    const editor = try Editor.createFromText(allocator, io, text, "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(2, 1));
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    // Upstream derives guide colors from the bracket highlight color: the
    // active pair uses the full color, inactive guides use it at 30% opacity
    // composited over the editor background.
    const active_fg = ui.cell.packColor(color(dark_bracket_highlight_colors[0]));
    const inner_fg = ui.cell.packColor(fadeOver(
        color(dark_bracket_highlight_colors[1]),
        0.3,
        color([3]u8{ 30, 30, 33 }),
    ));

    // The opening line keeps its text; a guide is not painted over `f`.
    try std.testing.expectEqual(@as(u32, 'f'), grid.cluster[grid.index(gutter, 0)]);

    // Cursor line 2 is inside the outer pair, which is highlighted at column 0.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 1)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 1)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 2)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 2)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 3)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 3)]);

    // The inner pair has its own guide at column 4 and is not active.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter + 4, 2)]);
    try std.testing.expectEqual(inner_fg, grid.fg[grid.index(gutter + 4, 2)]);
}

test "View: last visible line keeps bracket guides closing below the viewport" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "fn main() {\n" ++
        "    if (x) {\n" ++
        "        y();\n" ++
        "        z();\n" ++
        "    }\n" ++
        "}";
    // The status row leaves four text rows: lines 1-4 are visible.
    const editor = try Editor.createFromText(allocator, io, text, "test.zig", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const color_utils = @import("../vs/platform/theme/common/colorUtils.zig");
    const color_theme = @import("../vs/workbench/services/themes/common/colorThemeData.zig");
    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    // Distinct colors make the source of a guide unambiguous. The two pairs
    // use bracket levels 1 and 2, so both theme entries are needed.
    const theme = try color_theme.ColorThemeData.createUnloadedTheme(allocator, &registry, "test-dark", &.{
        .{ "editor.background", "#101010" },
        .{ "editorIndentGuide.background1", "#00ff00" },
        .{ "editorIndentGuide.activeBackground1", "#00ff00" },
        .{ "editorIndentGuide.background2", "#00ff00" },
        .{ "editorIndentGuide.activeBackground2", "#00ff00" },
        .{ "editorBracketPairGuide.background1", "#ff0000" },
        .{ "editorBracketPairGuide.activeBackground1", "#ff0000" },
        .{ "editorBracketPairGuide.background2", "#ff0000" },
        .{ "editorBracketPairGuide.activeBackground2", "#ff0000" },
    });
    defer theme.deinit();
    const palette = theme_colors_mod.ThemeColors.init(theme);

    try editor.setCursorPosition(Position.init(3, 1));
    const view = try View.init(allocator, editor);
    defer view.deinit();
    view.setThemeColors(&palette);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    const bracket_fg = ui.cell.packColor(.{ .r = 255, .g = 0, .b = 0 });

    // Line 3 sees the inner pair's guide at the shared level-2 cell.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter + 4, 2)]);
    try std.testing.expectEqual(bracket_fg, grid.fg[grid.index(gutter + 4, 2)]);

    // The enclosing pairs close on lines 5 and 6, below the viewport. Upstream
    // `indentGuides.ts` requests `visibleEndLineNumber + 1` so those guides
    // still reach the last visible line; without it the active indent guide
    // takes over that cell with the wrong color and position.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 3)]);
    try std.testing.expectEqual(bracket_fg, grid.fg[grid.index(gutter, 3)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter + 4, 3)]);
    try std.testing.expectEqual(bracket_fg, grid.fg[grid.index(gutter + 4, 3)]);
}

test "View: resizing the viewport recomputes guides for the new rows" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "if x:\n" ++
        "    if y:\n" ++
        "        z()\n" ++
        "    w()\n" ++
        "end";
    // Height 3 reserves the status row, so only lines 1-2 are visible.
    const editor = try Editor.createFromText(allocator, io, text, "test.zig", 40, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.paint();

    // Grow the viewport; `z()` is now the last visible line and must receive
    // its new guides even though the size change raises no guide event.
    editor.setViewport(40, 6);
    view.invalidate();
    try view.paint();

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    const guide_fg = ui.cell.packColor(color(indent_guide_color));
    const active_fg = ui.cell.packColor(color(indent_guide_active_color));
    // The caret on the unindented first line makes the level-1 scope active.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 2)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 2)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter + 4, 2)]);
    try std.testing.expectEqual(guide_fg, grid.fg[grid.index(gutter + 4, 2)]);
}

test "View: active indentation guide follows the cursor scope" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "root\n" ++
        "    child\n" ++
        "        grand\n" ++
        "    sibling\n" ++
        "root";
    const editor = try Editor.createFromText(allocator, io, text, "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(2, 1));
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    const active_fg = ui.cell.packColor(color(indent_guide_active_color));
    const normal_fg = ui.cell.packColor(color(indent_guide_color));

    // Upstream highlights the child scope opened by the caret line: `child`
    // opens `grand`, so line 3's level-2 guide is the active one.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 1)]);
    try std.testing.expectEqual(normal_fg, grid.fg[grid.index(gutter, 1)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 2)]);
    try std.testing.expectEqual(normal_fg, grid.fg[grid.index(gutter, 2)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter + 4, 2)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter + 4, 2)]);

    // `sibling` and the closing `root` keep normal guides.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 3)]);
    try std.testing.expectEqual(normal_fg, grid.fg[grid.index(gutter, 3)]);
}

test "View: contribution highlights are stored as model decorations" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "alpha beta alpha", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 1, 1, 6), .kind = .find_match },
        .{ .range = Range.init(1, 12, 1, 17), .kind = .find_match },
    });

    const decorations = try editor.model.getAllDecorations(1, false);
    defer allocator.free(decorations);
    try std.testing.expectEqual(@as(usize, 2), decorations.len);
    try std.testing.expectEqualStrings("findMatch", decorations[0].options.className.?);

    try view.setDecorations(&.{});
    const cleared = try editor.model.getAllDecorations(1, false);
    defer allocator.free(cleared);
    try std.testing.expectEqual(@as(usize, 0), cleared.len);
}

test "view: snippet placeholder decoration classes map to cell flags" {
    try std.testing.expectEqual(CellFlag.snippet_placeholder, decorationBit("snippet-placeholder").?);
    try std.testing.expectEqual(CellFlag.finish_snippet_placeholder, decorationBit("finish-snippet-placeholder").?);
    try std.testing.expectEqual(CellFlag.value_set_replacement, decorationBit("valueSetReplacement").?);
}

test "view: diagnostic decoration classes map to cell flags" {
    try std.testing.expectEqual(CellFlag.diagnostic_error, decorationBit("squiggly-error").?);
    try std.testing.expectEqual(CellFlag.diagnostic_warning, decorationBit("squiggly-warning").?);
    try std.testing.expectEqual(CellFlag.diagnostic_info, decorationBit("squiggly-info").?);
    try std.testing.expectEqual(CellFlag.diagnostic_hint, decorationBit("squiggly-hint").?);
    try std.testing.expectEqual(CellFlag.diagnostic_unnecessary, decorationBit("squiggly-unnecessary").?);
    try std.testing.expectEqual(CellFlag.diagnostic_inline_unnecessary, decorationBit("squiggly-inline-unnecessary").?);
    try std.testing.expectEqual(CellFlag.diagnostic_deprecated, decorationBit("squiggly-inline-deprecated").?);
    try std.testing.expectEqual(CellFlag.search_range_highlight, decorationBit("rangeHighlight").?);
}

test "view: diagnostic flags select terminal underline styles" {
    var error_style = ui.style.PaintStyle{};
    applyFlagPaint(&error_style, CellFlag.diagnostic_error, null);
    try std.testing.expect(error_style.underline == true);
    try std.testing.expectEqual(ui.UnderlineStyle.curly, error_style.underline_style);
    try std.testing.expectEqual(@as(u8, 241), error_style.color.?.r);
    try std.testing.expectEqual(@as(u8, 76), error_style.color.?.g);
    try std.testing.expectEqual(@as(u8, 76), error_style.color.?.b);

    var warning_style = ui.style.PaintStyle{};
    applyFlagPaint(&warning_style, CellFlag.diagnostic_warning, null);
    try std.testing.expectEqual(ui.UnderlineStyle.curly, warning_style.underline_style);

    var info_style = ui.style.PaintStyle{};
    applyFlagPaint(&info_style, CellFlag.diagnostic_info, null);
    try std.testing.expectEqual(ui.UnderlineStyle.curly, info_style.underline_style);

    var hint_style = ui.style.PaintStyle{};
    applyFlagPaint(&hint_style, CellFlag.diagnostic_hint, null);
    try std.testing.expectEqual(ui.UnderlineStyle.dotted, hint_style.underline_style);

    var unnecessary_style = ui.style.PaintStyle{};
    applyFlagPaint(&unnecessary_style, CellFlag.diagnostic_unnecessary, null);
    try std.testing.expect(unnecessary_style.dim == true);
    try std.testing.expect(unnecessary_style.underline == true);
    try std.testing.expectEqual(ui.UnderlineStyle.dashed, unnecessary_style.underline_style);

    var inline_unnecessary_style = ui.style.PaintStyle{};
    applyFlagPaint(&inline_unnecessary_style, CellFlag.diagnostic_inline_unnecessary, null);
    try std.testing.expect(inline_unnecessary_style.dim == true);
    try std.testing.expect(inline_unnecessary_style.underline != true);

    var deprecated_style = ui.style.PaintStyle{};
    applyFlagPaint(&deprecated_style, CellFlag.diagnostic_deprecated, null);
    try std.testing.expect(deprecated_style.strikethrough == true);
    try std.testing.expect(deprecated_style.underline != true);
}

test "view: selection fallbacks match the upstream registry defaults" {
    const dark = selectionFallback(.DARK);
    try std.testing.expectEqualSlices(u8, &selection_background_dark, &dark.background);
    try std.testing.expect(dark.foreground == null);

    const light = selectionFallback(.LIGHT);
    try std.testing.expectEqualSlices(u8, &selection_background_light, &light.background);
    try std.testing.expect(light.foreground == null);

    const hc_dark = selectionFallback(.HIGH_CONTRAST_DARK);
    try std.testing.expectEqualSlices(u8, &selection_background_hc_dark, &hc_dark.background);
    try std.testing.expectEqualSlices(u8, &selection_foreground_hc_dark, &hc_dark.foreground.?);

    const hc_light = selectionFallback(.HIGH_CONTRAST_LIGHT);
    try std.testing.expectEqualSlices(u8, &selection_background_hc_light, &hc_light.background);
    try std.testing.expectEqualSlices(u8, &selection_foreground_hc_light, &hc_light.foreground.?);
}

test "view: selection paint replaces reverse video and stays below decorations" {
    var style = ui.style.PaintStyle{};
    applyFlagPaint(&style, CellFlag.selected, null);
    try std.testing.expect(style.reverse != true);
    try std.testing.expectEqual(
        ui.cell.packColor(color(selection_background_dark)),
        ui.cell.packColor(style.background.?),
    );
    // The fallback foreground composited 30% toward the selection background.
    try std.testing.expectEqual(@as(u8, 154), style.color.?.r);
    try std.testing.expectEqual(@as(u8, 167), style.color.?.g);
    try std.testing.expectEqual(@as(u8, 179), style.color.?.b);

    // `SelectionsOverlay` is added before `DecorationsOverlay`, so a find match
    // keeps its own background inside a selection.
    var combined = ui.style.PaintStyle{};
    applyFlagPaint(&combined, CellFlag.selected | CellFlag.find_match, null);
    try std.testing.expectEqual(
        ui.cell.packColor(color(find_match_background)),
        ui.cell.packColor(combined.background.?),
    );
}

test "view: marker error ranges paint a curly underline" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var marker_service = MarkerService.init(allocator);
    defer marker_service.deinit();
    const marker_decorations = try MarkerDecorationsService.init(allocator, &marker_service);
    defer marker_decorations.deinit();

    const editor = try Editor.createFromText(allocator, io, "{\"a\": 1}", "broken.json", 24, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    editor.attachLanguageServices(null, &marker_service, marker_decorations);

    var resource = try markers_mod.Resource.fromUri(allocator, editor.model.uri());
    defer resource.deinit(allocator);
    try marker_service.changeOne("json", resource, &.{
        .{
            .message = "unexpected token",
            .severity = markers_mod.MarkerSeverity.Error,
            .start_line_number = 1,
            .start_column = 1,
            .end_line_number = 1,
            .end_column = 5,
        },
    }, null);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    var col: usize = 0;
    while (col < 4) : (col += 1) {
        const attrs = grid.attrs[grid.index(gutter + col, 0)];
        try std.testing.expect((attrs & ui.cell.Attr.underline) != 0);
        try std.testing.expectEqual(ui.UnderlineStyle.curly, ui.cell.underlineStyleOf(attrs));
    }
    try std.testing.expect((grid.attrs[grid.index(gutter + 4, 0)] & ui.cell.Attr.underline) == 0);
}

test "View: block decorations paint a bordered range under the text" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo\nthree\nfour", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var options = ModelDecorationOptions.init("block", .AlwaysGrowsWhenTypingAtEdges);
    options.blockClassName = "movedModified";
    const deltas = [_]ModelDeltaDecoration{
        .{ .range = Range.init(2, 1, 3, 1), .options = &options },
    };
    const ids = try editor.model.deltaDecorations(&.{}, &deltas, 63);
    defer allocator.free(ids);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    try std.testing.expectEqual(@as(usize, 1), view.block_nodes.items.len);
    const node = view.block_nodes.items[0];
    try std.testing.expect(node.hasClass(editor_css.block_decorations.Class.block_decorations_block));
    const style = node.style();
    try std.testing.expect(style.border_color != null);
    try std.testing.expectEqual(@as(f64, 1), style.border.?.top.?);
    try std.testing.expectEqual(@as(f64, 1), style.border.?.left.?);
    try std.testing.expectEqual(@as(f64, 1), style.border.?.right.?);
    try std.testing.expectEqual(@as(f64, 1), style.border.?.bottom.?);

    const box = view.surface.box_tree.find(node) orelse return error.MissingBox;
    try std.testing.expectEqual(@as(f64, @floatFromInt(editor.gutterWidth())), box.rect.x);
    // Line 2 starts at view row 1 and the range covers two rows.
    try std.testing.expectEqual(@as(f64, 1), box.rect.y);
    try std.testing.expectEqual(@as(f64, 2), box.rect.h);
    try std.testing.expectEqual(@as(u8, 139), style.border_color.?.r);
    try std.testing.expectEqual(@as(u8, 139), style.border_color.?.g);
    try std.testing.expectEqual(@as(u8, 139), style.border_color.?.b);
}

test "View: glyph margin paints a themed glyph and reports the gutter target" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo\nthree", "test.txt", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var options = ModelDecorationOptions.init("glyph", .AlwaysGrowsWhenTypingAtEdges);
    options.glyphMarginClassName = "glyph-error";
    const deltas = [_]ModelDeltaDecoration{
        .{ .range = Range.init(2, 1, 2, 1), .options = &options },
    };
    const ids = try editor.model.deltaDecorations(&.{}, &deltas, 64);
    defer allocator.free(ids);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    try std.testing.expectEqual(@as(usize, 1), editor.gutterGlyphWidth());
    try std.testing.expectEqual(@as(usize, 7), editor.gutterWidth());
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, 0x25CF), grid.cluster[grid.index(0, 1)]);
    try std.testing.expectEqual(ui.cell.packColor(.{ .r = 241, .g = 76, .b = 76 }), grid.fg[grid.index(0, 1)]);

    const target = try view.mouseTargetAt(0, 1);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.gutter_glyph_margin, target.type);
}

test "View: glyph margin compacts multiple lanes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo\nthree", "test.txt", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var left = ModelDecorationOptions.init("left-glyph", .AlwaysGrowsWhenTypingAtEdges);
    left.glyphMarginClassName = "glyph-error";
    left.glyphMargin = .{ .position = .Left, .persistLane = false };
    var right = ModelDecorationOptions.init("right-glyph", .AlwaysGrowsWhenTypingAtEdges);
    right.glyphMarginClassName = "glyph-warning";
    right.glyphMargin = .{ .position = .Right, .persistLane = false };
    var center = ModelDecorationOptions.init("center-glyph", .AlwaysGrowsWhenTypingAtEdges);
    center.glyphMarginClassName = "glyph-info";
    center.glyphMargin = .{ .position = .Center, .persistLane = false };
    const deltas = [_]ModelDeltaDecoration{
        .{ .range = Range.init(2, 1, 2, 1), .options = &left },
        .{ .range = Range.init(2, 1, 2, 1), .options = &right },
        .{ .range = Range.init(3, 1, 3, 1), .options = &center },
    };
    const ids = try editor.model.deltaDecorations(&.{}, &deltas, 65);
    defer allocator.free(ids);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    try std.testing.expectEqual(@as(usize, 2), editor.gutterGlyphWidth());
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, 0x25CF), grid.cluster[grid.index(0, 1)]);
    try std.testing.expectEqual(@as(u32, 0x25B2), grid.cluster[grid.index(1, 1)]);
    // Line 3 only has the center lane, so compaction puts it in the first cell.
    try std.testing.expectEqual(@as(u32, 0x25CF), grid.cluster[grid.index(0, 2)]);
    try std.testing.expect(grid.cluster[grid.index(1, 2)] != 0x25CF);
}

test "View: collapsed end-of-line markers paint an underline cell" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc\n", "broken.js", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var options = ModelDecorationOptions.init("squiggly-error", .AlwaysGrowsWhenTypingAtEdges);
    options.className = "squiggly-error";
    options.showIfCollapsed = true;
    const deltas = [_]ModelDeltaDecoration{
        // Just past the last character of a non-empty line.
        .{ .range = Range.init(1, 4, 1, 4), .options = &options },
        // An empty last line, the shape a missing-closing-brace diagnostic has.
        .{ .range = Range.init(2, 1, 2, 1), .options = &options },
    };
    const ids = try editor.model.deltaDecorations(&.{}, &deltas, 0);
    defer allocator.free(ids);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const past_text = grid.attrs[grid.index(gutter + 3, 0)];
    try std.testing.expect((past_text & ui.cell.Attr.underline) != 0);
    try std.testing.expectEqual(ui.UnderlineStyle.curly, ui.cell.underlineStyleOf(past_text));
    const empty_line = grid.attrs[grid.index(gutter, 1)];
    try std.testing.expect((empty_line & ui.cell.Attr.underline) != 0);
    try std.testing.expectEqual(ui.UnderlineStyle.curly, ui.cell.underlineStyleOf(empty_line));
}

test "View: init, paint and invalidate batch renders" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 20, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();

    try std.testing.expectEqual(@as(usize, 0), view.renderCount());
    try view.paint();
    try std.testing.expectEqual(@as(usize, 1), view.renderCount());
    try view.paint();
    try std.testing.expectEqual(@as(usize, 1), view.renderCount());

    view.invalidate();
    try std.testing.expect(view.needsRender());
    try view.paint();
    try std.testing.expectEqual(@as(usize, 2), view.renderCount());
    try std.testing.expect(!view.needsRender());
}

test "View: has no terminal-only rebuild or resize method" {
    try std.testing.expect(!@hasDecl(View, "rebuild"));
    try std.testing.expect(!@hasDecl(View, "resize"));
    try std.testing.expect(@hasDecl(View, "render"));
}

test "View: viewport change resizes in place and retains chrome roots" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "alpha\nbeta", "test.txt", 20, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();

    try view.paint();
    const root_before = view.root_node.?;
    const content_before = view.content_root.?;
    const gutter_before = view.gutter_root.?;
    const scrollbar_before = view.scrollbar_root.?;
    const status_before = view.status_root.?;

    editor.setViewport(30, 8);
    view.invalidate();
    try view.paint();

    try std.testing.expectEqual(@as(usize, 30), view.surface.document().cols);
    try std.testing.expectEqual(@as(usize, 8), view.surface.document().rows);
    try std.testing.expect(view.root_node.? == root_before);
    try std.testing.expect(view.content_root.? == content_before);
    try std.testing.expect(view.gutter_root.? == gutter_before);
    try std.testing.expect(view.scrollbar_root.? == scrollbar_before);
    try std.testing.expect(view.status_root.? == status_before);

    const row = try view.grid().rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "alpha") != null);
}

test "View: diff line backgrounds and filler rows composite over the dark theme" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo\nthree", "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var insert_options = ModelDecorationOptions.init("line-insert", .AlwaysGrowsWhenTypingAtEdges);
    insert_options.className = "line-insert";
    insert_options.isWholeLine = true;
    var filler_options = ModelDecorationOptions.init("diff-filler", .AlwaysGrowsWhenTypingAtEdges);
    filler_options.className = "diff-filler";
    filler_options.isWholeLine = true;
    const deltas = [_]ModelDeltaDecoration{
        .{ .range = Range.init(1, 1, 1, 1), .options = &insert_options },
        .{ .range = Range.init(2, 1, 2, 1), .options = &filler_options },
    };
    const ids = try editor.model.deltaDecorations(&.{}, &deltas, 60);
    defer allocator.free(ids);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    try std.testing.expectEqual(
        ui.cell.packColor(color(diff_insert_line_background)),
        grid.bg[grid.index(gutter, 0)],
    );
    try std.testing.expectEqual(
        ui.cell.packColor(color(diff_filler_background)),
        grid.bg[grid.index(gutter, 1)],
    );
    // The third row keeps the plain editor background (no value).
    try std.testing.expectEqual(@as(u32, 0), grid.bg[grid.index(gutter, 2)]);
}

test "View: char-insert and char-delete inline classes paint cell backgrounds" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abcd\nsecond", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var options = ModelDecorationOptions.init("char-insert", .AlwaysGrowsWhenTypingAtEdges);
    options.className = "char-insert";
    options.inlineClassName = "char-insert";
    const deltas = [_]ModelDeltaDecoration{
        .{ .range = Range.init(1, 2, 1, 3), .options = &options },
    };
    const ids = try editor.model.deltaDecorations(&.{}, &deltas, 61);
    defer allocator.free(ids);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    try std.testing.expectEqual(
        ui.cell.packColor(color(diff_insert_char_background)),
        grid.bg[grid.index(gutter + 1, 0)],
    );
    // The neighbouring character keeps the plain background (the current line
    // itself carries the cursor-line highlight).
    try std.testing.expectEqual(@as(u32, 0), grid.bg[grid.index(gutter, 1)]);
}

test "View: quick-diff gutter marker" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    editor.setLineDecorationsWidth(1);

    var options = ModelDecorationOptions.init("dirty-diff-added", .AlwaysGrowsWhenTypingAtEdges);
    options.linesDecorationsClassName = "dirty-diff-glyph dirty-diff-added primary";
    options.isWholeLine = true;
    const deltas = [_]ModelDeltaDecoration{
        .{ .range = Range.init(2, 1, 2, 1), .options = &options },
    };
    const ids = try editor.model.deltaDecorations(&.{}, &deltas, 62);
    defer allocator.free(ids);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(usize, 7), editor.gutterWidth());
    try std.testing.expectEqual(@as(usize, 5), editor.foldCellColumn());
    try std.testing.expectEqual(@as(usize, 6), editor.quickDiffCellColumn());
    const row0 = try rowText(view, allocator, 0);
    defer allocator.free(row0);
    const row1 = try rowText(view, allocator, 1);
    defer allocator.free(row1);
    try std.testing.expect(std.mem.indexOf(u8, row0, "+") == null);
    try std.testing.expectEqual(@as(u32, '+'), grid.cluster[grid.index(editor.quickDiffCellColumn(), 1)]);
    // The number and fold cells still line up before the marker cell.
    try std.testing.expect(std.mem.indexOf(u8, row1, "2") != null);
}

test "View: fold control sits before the quick-diff cell" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "class A {\n  void f() {\n    x();\n  }\n}",
        "test.zig",
        40,
        8,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    editor.setLineDecorationsWidth(1);
    const view = try View.init(allocator, editor);
    defer view.deinit();
    editor.refreshFoldingIfDirty();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '▾'), grid.cluster[grid.index(editor.foldCellColumn(), 0)]);
    var down = testMouse(.down, editor.foldCellColumn(), 0);
    try std.testing.expect(try view.dispatchMouse(&down));
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());

    // Clicking the quick-diff marker cell does not toggle the fold.
    var marker_click = testMouse(.down, editor.quickDiffCellColumn(), 0);
    _ = try view.dispatchMouse(&marker_click);
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());
}

test "View: gutter-only line highlight paints the margin" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo", "test.txt", 30, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();

    view.terminal_view_host.options.set(.renderLineHighlight, .gutter);
    const option_count = @typeInfo(editor_options.EditorOption).@"enum".field_names.len;
    var changed: [option_count]bool = @splat(false);
    changed[@backingInt(editor_options.EditorOption.renderLineHighlight)] = true;
    const event = view_events.ViewConfigurationChangedEvent.init(
        editor_options.ConfigurationChangedEvent.init(&changed),
    );
    _ = view.terminal_view_host.viewRef().onConfigurationChanged(&event);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    try std.testing.expect(view.terminal_view_host.currentLineMargin().renderedLine(1).?.in_margin);
    const grid = view.surface.grid();
    try std.testing.expectEqual(ui.cell.packColor(.{ .r = 40, .g = 40, .b = 40 }), grid.bg[grid.index(0, 0)]);
    try std.testing.expect(grid.bg[grid.index(editor.gutterWidth(), 0)] != ui.cell.packColor(.{ .r = 40, .g = 40, .b = 40 }));
}

test "View: margin decorations paint the gutter row" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo\nthree", "test.txt", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var options = ModelDecorationOptions.init("insert-margin", .AlwaysGrowsWhenTypingAtEdges);
    options.marginClassName = "gutter-insert";
    const deltas = [_]ModelDeltaDecoration{
        .{ .range = Range.init(2, 1, 2, 1), .options = &options },
    };
    const ids = try editor.model.deltaDecorations(&.{}, &deltas, 66);
    defer allocator.free(ids);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    try std.testing.expectEqual(
        ui.cell.packColor(.{ .r = 72, .g = 126, .b = 2 }),
        grid.bg[grid.index(0, 1)],
    );
}

test "View: line decoration classes paint the marker cell" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo\nthree", "test.txt", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var options = ModelDecorationOptions.init("insert-line", .AlwaysGrowsWhenTypingAtEdges);
    options.linesDecorationsClassName = "insert-sign";
    const deltas = [_]ModelDeltaDecoration{
        .{ .range = Range.init(2, 1, 2, 1), .options = &options },
    };
    const ids = try editor.model.deltaDecorations(&.{}, &deltas, 67);
    defer allocator.free(ids);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(usize, 1), editor.lineDecorationsWidth());
    try std.testing.expectEqual(@as(u32, '+'), grid.cluster[grid.index(editor.gutterWidth() - 1, 1)]);
    try std.testing.expectEqual(ui.cell.packColor(.{ .r = 72, .g = 126, .b = 2 }), grid.fg[grid.index(editor.gutterWidth() - 1, 1)]);

    const removed = try editor.model.deltaDecorations(ids, &.{}, 68);
    defer allocator.free(removed);
    view.invalidate();
    try view.renderAnsi(&out.writer);
    try std.testing.expectEqual(@as(usize, 0), editor.lineDecorationsWidth());
}

test "View: focus-only line highlight follows forwarded focus" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo", "test.txt", 30, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();

    view.terminal_view_host.options.set(.renderLineHighlight, .line);
    view.terminal_view_host.options.set(.renderLineHighlightOnlyWhenFocus, true);
    const option_count = @typeInfo(editor_options.EditorOption).@"enum".field_names.len;
    var changed: [option_count]bool = @splat(false);
    changed[@backingInt(editor_options.EditorOption.renderLineHighlight)] = true;
    changed[@backingInt(editor_options.EditorOption.renderLineHighlightOnlyWhenFocus)] = true;
    const event = view_events.ViewConfigurationChangedEvent.init(
        editor_options.ConfigurationChangedEvent.init(&changed),
    );
    _ = view.terminal_view_host.viewRef().onConfigurationChanged(&event);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);
    try std.testing.expect(view.surface.grid().bg[view.surface.grid().index(editor.gutterWidth(), 0)] !=
        ui.cell.packColor(color(current_line_background)));

    _ = view.setFocused(true);
    try view.renderAnsi(&out.writer);
    try std.testing.expectEqual(
        ui.cell.packColor(color(current_line_background)),
        view.surface.grid().bg[view.surface.grid().index(editor.gutterWidth(), 0)],
    );

    _ = view.setFocused(false);
    try view.renderAnsi(&out.writer);
    try std.testing.expect(view.surface.grid().bg[view.surface.grid().index(editor.gutterWidth(), 0)] !=
        ui.cell.packColor(color(current_line_background)));
}

test "View: rulers paint a guide column" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo", "test.txt", 40, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();

    view.terminal_view_host.options.set(.rulers, &.{
        .{ .column = 10, .color = null },
    });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    const col = editor.gutterWidth() + 10 - 1;
    try std.testing.expectEqual(@as(u32, 0x2502), grid.cluster[grid.index(col, 0)]);
}

test "View: scroll decoration shadows the first row" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11", "test.txt", 30, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);
    const shadow = ui.cell.packColor(.{ .r = 0, .g = 0, .b = 0 });
    try std.testing.expect(view.surface.grid().bg[view.surface.grid().index(editor.gutterWidth(), 0)] != shadow);

    _ = editor.scrollViewLines(3);
    view.invalidate();
    try view.renderAnsi(&out.writer);
    try std.testing.expectEqual(shadow, view.surface.grid().bg[view.surface.grid().index(editor.gutterWidth(), 0)]);
}

test "View: glyph hover message becomes a content tooltip" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo\nthree", "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var options = ModelDecorationOptions.init("glyph-tip", .AlwaysGrowsWhenTypingAtEdges);
    options.glyphMarginClassName = "glyph-error";
    options.glyphMarginHoverMessage = "glyph message";
    const deltas = [_]ModelDeltaDecoration{
        .{ .range = Range.init(1, 1, 1, 1), .options = &options },
    };
    const ids = try editor.model.deltaDecorations(&.{}, &deltas, 69);
    defer allocator.free(ids);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const target = try view.mouseTargetAt(0, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.gutter_glyph_margin, target.type);
    try std.testing.expect(view.terminal_view_host.glyphTooltipAt(1, 0) != null);
    view.setGlyphHover(target);
    try std.testing.expect(view.glyph_tooltip.visible);
    try view.renderAnsi(&out.writer);

    var found = false;
    var row: usize = 0;
    while (row < view.surface.grid().rows) : (row += 1) {
        const text = try view.surface.grid().rowText(allocator, row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "glyph message") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    view.clearGlyphHover();
    try view.renderAnsi(&out.writer);
    try std.testing.expect(view.surface.grid().bg[view.surface.grid().index(editor.gutterWidth(), 1)] !=
        ui.cell.packColor(.{ .r = 50, .g = 50, .b = 55 }));
}

test "View: top inset reserves rows above the text" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo", "test.txt", 30, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();
    view.setTopInset(1);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(editor.gutterWidth() + 1, 0)]);
    try std.testing.expectEqual(@as(u32, 'o'), grid.cluster[grid.index(editor.gutterWidth(), 1)]);
    const zone_target = try view.mouseTargetAt(editor.gutterWidth() + 1, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.content_empty, zone_target.type);
    const text_target = try view.mouseTargetAt(editor.gutterWidth() + 1, 1);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.content_text, text_target.type);
}

test "View: bracket colorization follows a line insertion above the pair" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "plain\n[ ]\nplain", "test.zig", 30, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    const view = try View.init(allocator, editor);
    defer view.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const level0 = dark_bracket_highlight_colors[0];
    var grid = view.surface.grid();
    var open = ui.cell.unpackColor(grid.fg[grid.index(gutter, 1)]);
    try std.testing.expectEqual(level0[0], open.r);

    // A new line above the pair shifts it down; the colorization has to follow
    // the reused AST node instead of staying on its pre-edit row.
    try editor.typeCharacter("\n");
    try view.refresh();
    try view.renderAnsi(&out.writer);
    grid = view.surface.grid();
    const plain = ui.cell.unpackColor(grid.fg[grid.index(gutter, 1)]);
    try std.testing.expect(!(plain.r == level0[0] and plain.g == level0[1] and plain.b == level0[2]));
    open = ui.cell.unpackColor(grid.fg[grid.index(gutter, 2)]);
    try std.testing.expectEqual(level0[0], open.r);
    try std.testing.expectEqual(level0[1], open.g);
    try std.testing.expectEqual(level0[2], open.b);
}
