// Port of `src/vs/editor/contrib/smartSelect/browser/smartSelect.ts`.
//
// Adaptations for this port:
//  * providers are passed explicitly instead of coming from a language-feature
//    registry;
//  * the run is synchronous because the TUI has no async provider service;
//  * controller cache invalidation compares the current selections and model
//    version instead of listening to cursor events;
//  * the action wrappers expose the upstream metadata and are driven by the TUI.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const languages = @import("../../../common/languages.zig");
const SelectionRange = languages.SelectionRange;
const SelectionRangeProvider = languages.SelectionRangeProvider;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const editor_extensions = @import("../../../browser/editorExtensions.zig");
const EditorAction = editor_extensions.EditorAction;
const WordSelectionRangeProvider = @import("./wordSelections.zig").WordSelectionRangeProvider;
const BracketSelectionRangeProvider = @import("./bracketSelections.zig").BracketSelectionRangeProvider;

pub const SelectionRangesOptions = struct {
    select_leading_and_trailing_whitespace: bool = true,
    select_subwords: bool = true,
};

pub const SelectionRanges = struct {
    index: usize,
    ranges: []const Range,
};

/// The portable part of upstream's `SelectionRanges`: compare each range with
/// the current one and skip over equal consecutive ranges.
pub fn moveSelectionRanges(state: *SelectionRanges, forward: bool) void {
    var current = state.index;
    while (true) {
        const next: isize = @as(isize, @intCast(current)) + (if (forward) @as(isize, 1) else -1);
        if (next < 0 or next >= state.ranges.len) break;
        const next_index: usize = @intCast(next);
        if (Range.equalsRange(state.ranges[next_index], state.ranges[current])) {
            current = next_index;
            continue;
        }
        current = next_index;
        break;
    }
    state.index = current;
}

pub const SmartSelectController = struct {
    allocator: Allocator,
    providers: []const SelectionRangeProvider,
    options: SelectionRangesOptions,
    state: ?[]SelectionRanges = null,
    state_selections: ?[]Selection = null,
    state_version: u32 = 0,

    pub fn init(
        allocator: Allocator,
        providers: []const SelectionRangeProvider,
        options: SelectionRangesOptions,
    ) SmartSelectController {
        return .{
            .allocator = allocator,
            .providers = providers,
            .options = options,
        };
    }

    pub fn deinit(self: *SmartSelectController) void {
        self.clearState();
    }

    fn clearState(self: *SmartSelectController) void {
        if (self.state) |states| {
            for (states) |state| self.allocator.free(state.ranges);
            self.allocator.free(states);
            self.state = null;
        }
        if (self.state_selections) |selections| {
            self.allocator.free(selections);
            self.state_selections = null;
        }
        self.state_version = 0;
    }

    fn stateMatches(self: *const SmartSelectController, model: *TextModel, selections: []const Selection) bool {
        if (self.state == null or self.state_selections == null) return false;
        if (self.state_version != model.getVersionId()) return false;
        const cached = self.state_selections.?;
        if (cached.len != selections.len) return false;
        for (cached, selections) |old, new| {
            if (!old.equalsSelection(&new)) return false;
        }
        return true;
    }

    fn replaceStateSelections(self: *SmartSelectController, selections: []const Selection) !void {
        const copy = try self.allocator.dupe(Selection, selections);
        if (self.state_selections) |old| self.allocator.free(old);
        self.state_selections = copy;
    }

    /// Runs one expand/shrink step. Returns null when there is no state (this
    /// mirrors upstream's early return when no provider produced ranges).
    /// The returned selections are owned by the caller.
    pub fn run(
        self: *SmartSelectController,
        model: *TextModel,
        selections: []const Selection,
        forward: bool,
    ) !?[]Selection {
        if (!self.stateMatches(model, selections)) self.clearState();

        if (self.state == null) {
            try self.computeState(model, selections);
            if (self.state == null) return null;
        }

        const states = self.state.?;
        const result = try self.allocator.alloc(Selection, states.len);
        errdefer self.allocator.free(result);

        for (states, 0..) |*state, index| {
            moveSelectionRanges(state, forward);
            const range = state.ranges[state.index];
            result[index] = Selection.fromPositions(range.getStartPosition(), range.getEndPosition());
        }

        try self.replaceStateSelections(result);
        return result;
    }

    fn computeState(self: *SmartSelectController, model: *TextModel, selections: []const Selection) !void {
        const positions = try self.allocator.alloc(Position, selections.len);
        defer self.allocator.free(positions);
        for (selections, 0..) |selection, index| positions[index] = selection.getPosition();

        const provided = try provideSelectionRanges(
            self.allocator,
            model,
            positions,
            self.providers,
            self.options,
            CancellationToken.None,
        );
        defer freeSelectionRanges(self.allocator, provided);

        if (provided.len != selections.len) return;

        const states = try self.allocator.alloc(SelectionRanges, selections.len);
        var initialized: usize = 0;
        errdefer {
            for (states[0..initialized]) |state| self.allocator.free(state.ranges);
            self.allocator.free(states);
        }

        for (selections, 0..) |selection, index| {
            const start = selection.getStartPosition();
            const end = selection.getEndPosition();

            var filtered = ArrayList(Range).init(self.allocator);
            defer filtered.deinit();
            for (provided[index]) |range| {
                if (Range.containsPosition(&range, &start) and Range.containsPosition(&range, &end)) {
                    try filtered.append(range);
                }
            }

            const ranges = try self.allocator.alloc(Range, filtered.items.len + 1);
            ranges[0] = Range.fromPositions(start, end);
            @memcpy(ranges[1..], filtered.items);
            states[index] = .{ .index = 0, .ranges = ranges };
            initialized += 1;
        }

        self.state = states;
        self.state_version = model.getVersionId();
        try self.replaceStateSelections(selections);
    }
};

pub fn freeSelectionRanges(allocator: Allocator, ranges: [][]Range) void {
    for (ranges) |bucket| allocator.free(bucket);
    allocator.free(ranges);
}

/// Port of upstream's `provideSelectionRanges`. Providers are appended to the
/// always-present word provider; the bracket provider is added when no
/// language provider exists, exactly like upstream.
pub fn provideSelectionRanges(
    allocator: Allocator,
    model: *TextModel,
    positions: []const Position,
    providers: []const SelectionRangeProvider,
    options: SelectionRangesOptions,
    token: CancellationToken,
) ![][]Range {
    var provider_list = ArrayList(SelectionRangeProvider).init(allocator);
    defer provider_list.deinit();
    try provider_list.appendSlice(providers);

    var word_provider = WordSelectionRangeProvider.init(options.select_subwords);
    const word_interface = word_provider.interface();
    try provider_list.append(word_interface);

    var bracket_provider = BracketSelectionRangeProvider{};
    const bracket_interface = bracket_provider.interface();
    if (provider_list.items.len == 1) {
        try provider_list.insert(0, bracket_interface);
    }

    var raw = ArrayList(ArrayList(Range)).init(allocator);
    defer {
        for (raw.items) |*bucket| bucket.deinit();
        raw.deinit();
    }
    try raw.ensureTotalCapacity(positions.len);
    for (0..positions.len) |_| {
        try raw.append(ArrayList(Range).init(allocator));
    }

    for (provider_list.items) |provider| {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const all = provider.provide_selection_ranges(
            provider.context,
            arena_state.allocator(),
            model,
            positions,
            token,
        ) catch continue;
        if (all.len != positions.len) continue;

        for (all, 0..) |provider_ranges, index| {
            if (index >= raw.items.len) break;
            for (provider_ranges) |selection_range| {
                if (Range.containsPosition(&selection_range.range, &positions[index])) {
                    try raw.items[index].append(selection_range.range);
                }
            }
        }
    }

    const result = try allocator.alloc([]Range, positions.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |bucket| allocator.free(bucket);
        allocator.free(result);
    }

    for (raw.items, 0..) |*bucket, index| {
        result[index] = try finishBucket(allocator, model, bucket.items, options);
        initialized += 1;
    }
    return result;
}

fn finishBucket(
    allocator: Allocator,
    model: *TextModel,
    raw_ranges: []const Range,
    options: SelectionRangesOptions,
) ![]Range {
    if (raw_ranges.len == 0) return allocator.alloc(Range, 0);

    std.sort.heap(Range, @constCast(raw_ranges), {}, rangeLessThan);

    var one = ArrayList(Range).init(allocator);
    defer one.deinit();
    var last: ?Range = null;
    for (raw_ranges) |range| {
        if (last == null) {
            try one.append(range);
            last = range;
            continue;
        }
        const previous = last.?;
        if (Range.containsRange(&range, &previous) and !Range.equalsRange(range, previous)) {
            try one.append(range);
            last = range;
        }
    }

    if (!options.select_leading_and_trailing_whitespace or one.items.len == 0) {
        return one.toOwnedSlice();
    }

    var with_trivia = ArrayList(Range).init(allocator);
    defer with_trivia.deinit();
    try with_trivia.append(one.items[0]);
    var index: usize = 1;
    while (index < one.items.len) : (index += 1) {
        const prev = one.items[index - 1];
        const cur = one.items[index];
        if (cur.startLineNumber != prev.startLineNumber or cur.endLineNumber != prev.endLineNumber) {
            const range_no_whitespace = Range.init(
                prev.startLineNumber,
                try model.getLineFirstNonWhitespaceColumn(prev.startLineNumber),
                prev.endLineNumber,
                try model.getLineLastNonWhitespaceColumn(prev.endLineNumber),
            );
            if (Range.containsRange(&range_no_whitespace, &prev) and
                !Range.equalsRange(range_no_whitespace, prev) and
                Range.containsRange(&cur, &range_no_whitespace) and
                !Range.equalsRange(cur, range_no_whitespace))
            {
                try with_trivia.append(range_no_whitespace);
            }

            const range_full = Range.init(
                prev.startLineNumber,
                1,
                prev.endLineNumber,
                model.getLineMaxColumn(prev.endLineNumber),
            );
            if (Range.containsRange(&range_full, &prev) and
                !Range.equalsRange(range_full, range_no_whitespace) and
                Range.containsRange(&cur, &range_full) and
                !Range.equalsRange(cur, range_full))
            {
                try with_trivia.append(range_full);
            }
        }
        try with_trivia.append(cur);
    }
    return with_trivia.toOwnedSlice();
}

fn rangeLessThan(_: void, a: Range, b: Range) bool {
    const a_start = a.getStartPosition();
    const b_start = b.getStartPosition();
    if (a_start.isBefore(b_start)) return false;
    if (b_start.isBefore(a_start)) return true;

    const a_end = a.getEndPosition();
    const b_end = b.getEndPosition();
    if (a_end.isBefore(b_end)) return true;
    if (b_end.isBefore(a_end)) return false;
    return false;
}

pub const ExpandSelectionAction = struct {
    pub const id = "editor.action.smartSelect.expand";
    pub const label = "Expand Selection";
    pub const description = "Expand Selection";
    pub const keybinding = editor_extensions.Keybinding{
        .key = "right",
        .shift = true,
        .alt = true,
        .weight = .editor_contrib,
    };

    context: *anyopaque,
    run_editor: *const fn (context: *anyopaque) anyerror!void,

    pub fn init(context: *anyopaque, run_editor: *const fn (context: *anyopaque) anyerror!void) ExpandSelectionAction {
        return .{ .context = context, .run_editor = run_editor };
    }

    pub fn run(self: *ExpandSelectionAction) !void {
        return self.run_editor(self.context);
    }

    pub fn editorAction(self: *ExpandSelectionAction) EditorAction {
        return EditorAction.init(.{
            .id = id,
            .label = label,
            .description = description,
            .keybinding = keybinding,
            .context = self,
            .run = runEditorAction,
        });
    }

    fn runEditorAction(context: *anyopaque) anyerror!void {
        const self: *ExpandSelectionAction = @ptrCast(@alignCast(context));
        return self.run();
    }
};

pub const ShrinkSelectionAction = struct {
    pub const id = "editor.action.smartSelect.shrink";
    pub const label = "Shrink Selection";
    pub const description = "Shrink Selection";
    pub const keybinding = editor_extensions.Keybinding{
        .key = "left",
        .shift = true,
        .alt = true,
        .weight = .editor_contrib,
    };

    context: *anyopaque,
    run_editor: *const fn (context: *anyopaque) anyerror!void,

    pub fn init(context: *anyopaque, run_editor: *const fn (context: *anyopaque) anyerror!void) ShrinkSelectionAction {
        return .{ .context = context, .run_editor = run_editor };
    }

    pub fn run(self: *ShrinkSelectionAction) !void {
        return self.run_editor(self.context);
    }

    pub fn editorAction(self: *ShrinkSelectionAction) EditorAction {
        return EditorAction.init(.{
            .id = id,
            .label = label,
            .description = description,
            .keybinding = keybinding,
            .context = self,
            .run = runEditorAction,
        });
    }

    fn runEditorAction(context: *anyopaque) anyerror!void {
        const self: *ShrinkSelectionAction = @ptrCast(@alignCast(context));
        return self.run();
    }
};

const ActionEditor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ActionCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const action_registry = @import("../../../../platform/actions/common/actions.zig");
fn expandSelection(editor: *ActionEditor) !void {
    try editor.growSelection(true);
}
fn shrinkSelection(editor: *ActionEditor) !void {
    try editor.growSelection(false);
}

pub const editor_actions = [_]action_registry.Action2{
    ActionCommand.action(.{ .id = "editor.action.smartSelect.expand", .title = "Expand Selection", .category = "Selection" }, false, expandSelection),
    ActionCommand.action(.{ .id = "editor.action.smartSelect.grow", .title = "Expand Selection", .category = "Selection" }, false, expandSelection),
    ActionCommand.action(.{ .id = "editor.action.smartSelect.shrink", .title = "Shrink Selection", .category = "Selection" }, false, shrinkSelection),
};
