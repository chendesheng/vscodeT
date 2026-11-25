// Terminal adaptation of editor decoration collections. The model owns all
// decoration ranges; the terminal view only reads them for painting.
const editorBrowser = @import("../../editorBrowser.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const model_types = @import("../../../common/model.zig");
const OverviewRulerLane = model_types.OverviewRulerLane;
const ModelDecorationOptions = model_types.ModelDecorationOptions;
const ModelDeltaDecoration = model_types.ModelDeltaDecoration;

pub const overview_find_color = [3]u8{ 96, 66, 22 };
pub const overview_current_find_color = [3]u8{ 150, 90, 0 };
pub const overview_bracket_color = [3]u8{ 92, 92, 92 };
pub const overview_word_color = [3]u8{ 78, 78, 78 };
pub const overview_word_strong_color = [3]u8{ 96, 80, 96 };

pub const DecorationOwner = struct {
    pub const find: usize = 1;
    pub const bracket: usize = 2;
    pub const word: usize = 3;
    pub const hover: usize = 4;
    pub const search: usize = 5;
    pub const marker_selection: usize = 6;
    /// Vim/Helix incremental-search highlights. Separate from the Search view
    /// result range above, so the two never clear each other.
    pub const incremental_search: usize = 7;
};

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
