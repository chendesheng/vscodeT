// Port of
// `src/vs/editor/contrib/stickyScroll/browser/stickyScrollProvider.ts`.
//
// Terminal adaptations:
// - a disposable request represents each asynchronous outline computation;
// - candidate slices are owned by the caller and freed with the provider's
//   allocator;
// - hidden ranges come from the terminal projected view model.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Range = @import("../../../common/core/range.zig").Range;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const sticky_element = @import("./stickyScrollElement.zig");
const StickyRange = sticky_element.StickyRange;
const StickyModel = sticky_element.StickyModel;
const sticky_model_provider = @import("./stickyScrollModelProvider.zig");
const StickyModelProvider = sticky_model_provider.StickyModelProvider;
const outline_mod = @import("../../documentSymbols/browser/outlineModel.zig");
const ModelProvider = sticky_model_provider.ModelProvider;

/// Port of `StickyLineCandidate`.
pub const StickyLineCandidate = struct {
    start_line_number: usize,
    end_line_number: usize,
    /// Top of the sticky row, in cells, relative to the widget.
    top: usize,
    /// Height of the sticky row, in cells.
    height: usize,
};

/// Port of `IStickyLineCandidateProvider`.
pub const IStickyLineCandidateProvider = struct {
    context: *anyopaque,
    dispose: *const fn (context: *anyopaque) void,
    get_version_id: *const fn (context: *anyopaque) ?u32,
    update: *const fn (context: *anyopaque) anyerror!void,
    get_candidate_sticky_lines_intersecting: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        range: StickyRange,
    ) anyerror![]StickyLineCandidate,

    pub fn disposeProvider(self: IStickyLineCandidateProvider) void {
        self.dispose(self.context);
    }
};

/// Port of `StickyLineCandidateProvider`.
pub const StickyLineCandidateProvider = struct {
    allocator: Allocator,
    editor: *Editor,
    model_provider: StickyModelProvider,
    model: ?*StickyModel = null,
    pending: ?*outline_mod.OutlineRequest = null,
    version: u32 = 0,
    default_model: ModelProvider = .outline_model,
    on_did_change: Emitter(void),

    pub fn init(allocator: Allocator, editor: *Editor) StickyLineCandidateProvider {
        return .{
            .allocator = allocator,
            .editor = editor,
            .model_provider = StickyModelProvider.init(allocator, editor),
            .on_did_change = Emitter(void).init(allocator),
        };
    }

    pub fn reset(self: *StickyLineCandidateProvider) void {
        if (self.pending) |request| request.cancel();
        self.pending = null;
        self.clearModel();
        self.version = 0;
    }

    pub fn dispose(self: *StickyLineCandidateProvider) void {
        self.reset();
        self.on_did_change.deinit();
    }

    pub fn interface(self: *StickyLineCandidateProvider) IStickyLineCandidateProvider {
        return .{
            .context = self,
            .dispose = disposeInterface,
            .get_version_id = getVersionIdInterface,
            .update = updateInterface,
            .get_candidate_sticky_lines_intersecting = getCandidatesInterface,
        };
    }

    fn disposeInterface(context: *anyopaque) void {
        const self: *StickyLineCandidateProvider = @ptrCast(@alignCast(context));
        self.dispose();
    }

    fn getVersionIdInterface(context: *anyopaque) ?u32 {
        const self: *StickyLineCandidateProvider = @ptrCast(@alignCast(context));
        return self.getVersionId();
    }

    fn updateInterface(context: *anyopaque) anyerror!void {
        const self: *StickyLineCandidateProvider = @ptrCast(@alignCast(context));
        return self.update();
    }

    fn getCandidatesInterface(
        context: *anyopaque,
        allocator: Allocator,
        range: StickyRange,
    ) anyerror![]StickyLineCandidate {
        const self: *StickyLineCandidateProvider = @ptrCast(@alignCast(context));
        return self.getCandidateStickyLinesIntersecting(allocator, range);
    }

    /// Version id of the currently cached sticky model.
    pub fn getVersionId(self: *const StickyLineCandidateProvider) ?u32 {
        return if (self.model) |model| model.version else null;
    }

    /// Cancel the previous update and publish the completed sticky model.
    pub fn update(self: *StickyLineCandidateProvider) !void {
        if (self.pending) |request| request.cancel();
        self.pending = null;
        if (!self.editor.hasModel() or self.editor.model.isTooLargeForTokenization()) {
            self.clearModel();
            try self.on_did_change.fire({});
            return;
        }

        if (self.default_model == .outline_model) {
            if (self.editor.language_features) |features| {
                const providers = try features.document_symbol_provider.ordered(self.allocator, self.editor.model, false);
                defer self.allocator.free(providers);
                self.version = self.editor.model.getVersionId();
                self.pending = try outline_mod.OutlineRequest.start(self.allocator, self.editor.model, providers, self, outlineReady);
                return;
            }
        }
        const next = try self.model_provider.update(self.default_model);
        self.clearModel();
        self.model = next;
        try self.on_did_change.fire({});
    }

    fn outlineReady(context: *anyopaque, outline: *outline_mod.OutlineModel) void {
        const self: *StickyLineCandidateProvider = @ptrCast(@alignCast(context));
        self.pending = null;
        defer outline.deinit();
        if (!self.editor.hasModel() or self.version != self.editor.model.getVersionId()) return;
        const preferred = if (self.model) |previous| previous.outline_provider_id else null;
        const next = (self.model_provider.fromOutline(outline, preferred) catch null) orelse
            (self.model_provider.modelFromIndentation(self.editor.model) catch null);
        self.clearModel();
        self.model = next;
        self.on_did_change.fire({}) catch {};
    }

    fn clearModel(self: *StickyLineCandidateProvider) void {
        if (self.model) |model| model.deinit();
        self.model = null;
    }

    /// Port of `getCandidateStickyLinesIntersecting`.
    pub fn getCandidateStickyLinesIntersecting(
        self: *StickyLineCandidateProvider,
        allocator: Allocator,
        range: StickyRange,
    ) ![]StickyLineCandidate {
        const model = self.model orelse return try allocator.alloc(StickyLineCandidate, 0);
        const element = model.element orelse return try allocator.alloc(StickyLineCandidate, 0);

        var candidates = std.array_list.Managed(StickyLineCandidate).init(allocator);
        errdefer candidates.deinit();
        try self.collectCandidates(range, element, &candidates, 0, 0, -1);
        const filtered = try self.filterHiddenRanges(allocator, candidates.items);
        candidates.deinit();
        return filtered;
    }

    /// Port of `getCandidateStickyLinesIntersectingFromStickyModel`.
    fn collectCandidates(
        self: *StickyLineCandidateProvider,
        range: StickyRange,
        outline_element: *sticky_element.StickyElement,
        result: *std.array_list.Managed(StickyLineCandidate),
        depth: usize,
        top: usize,
        last_start_line_number: isize,
    ) !void {
        if (outline_element.children.len == 0) return;

        const children = outline_element.children;
        const start_lines = try self.allocator.alloc(usize, children.len);
        defer self.allocator.free(start_lines);

        var start_line_count: usize = 0;
        for (children) |child| {
            if (child.range) |child_range| {
                start_lines[start_line_count] = child_range.start_line_number;
                start_line_count += 1;
            }
        }

        const lower_bound = updateIndex(binarySearch(
            start_lines[0..start_line_count],
            range.start_line_number,
        ));
        const upper_bound = updateIndex(binarySearch(
            start_lines[0..start_line_count],
            range.end_line_number,
        ));

        var index = lower_bound;
        while (index <= upper_bound) : (index += 1) {
            if (index >= children.len) break;
            const child = children[index];
            const child_range = child.range orelse continue;
            const start_line_number = child_range.start_line_number;
            const end_line_number = child_range.end_line_number;

            if (end_line_number > start_line_number + 1 and
                range.start_line_number <= end_line_number + 1 and
                start_line_number - 1 <= range.end_line_number and
                @as(isize, @intCast(start_line_number)) != last_start_line_number and
                self.editor.model.isValidRange(Range.init(start_line_number, 1, end_line_number, 1)))
            {
                const height: usize = 1;
                try result.append(.{
                    .start_line_number = start_line_number,
                    .end_line_number = end_line_number - 1,
                    .top = top,
                    .height = height,
                });
                try self.collectCandidates(
                    range,
                    child,
                    result,
                    depth + 1,
                    top + height,
                    @intCast(start_line_number),
                );
            }
        }
    }

    /// Port of `filterHiddenRanges`.
    fn filterHiddenRanges(
        self: *StickyLineCandidateProvider,
        allocator: Allocator,
        candidates: []const StickyLineCandidate,
    ) ![]StickyLineCandidate {
        const hidden_ranges = self.editor.view_lines.getHiddenAreas();
        if (hidden_ranges.len == 0) return allocator.dupe(StickyLineCandidate, candidates);

        var result = std.array_list.Managed(StickyLineCandidate).init(allocator);
        errdefer result.deinit();
        for (candidates) |candidate| {
            var hidden = false;
            for (hidden_ranges) |hidden_range| {
                if (candidate.start_line_number >= hidden_range.startLineNumber and
                    candidate.end_line_number <= hidden_range.endLineNumber + 1)
                {
                    hidden = true;
                    break;
                }
            }
            if (!hidden) try result.append(candidate);
        }
        return result.toOwnedSlice();
    }

    /// Port of `updateIndex`.
    fn updateIndex(index: isize) usize {
        if (index == -1) return 0;
        if (index < 0) return @intCast(-index - 2);
        return @intCast(index);
    }

    /// Port of `binarySearch` for strictly ascending line numbers: returns the
    /// found index or `-insertionPoint - 1`.
    fn binarySearch(values: []const usize, target: usize) isize {
        var low: usize = 0;
        var high: usize = values.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (target < values[mid]) {
                high = mid;
            } else if (target > values[mid]) {
                low = mid + 1;
            } else {
                return @intCast(mid);
            }
        }
        return -@as(isize, @intCast(low)) - 1;
    }
};

const testing = std.testing;

test "sticky candidate binarySearch and updateIndex" {
    const values = [_]usize{ 2, 5, 9 };
    try testing.expectEqual(@as(isize, 0), StickyLineCandidateProvider.binarySearch(&values, 2));
    try testing.expectEqual(@as(isize, 1), StickyLineCandidateProvider.binarySearch(&values, 5));
    try testing.expectEqual(@as(isize, -1), StickyLineCandidateProvider.binarySearch(&values, 1));
    try testing.expectEqual(@as(isize, -3), StickyLineCandidateProvider.binarySearch(&values, 7));
    try testing.expectEqual(@as(usize, 0), StickyLineCandidateProvider.updateIndex(-1));
    try testing.expectEqual(@as(usize, 1), StickyLineCandidateProvider.updateIndex(-3));
    try testing.expectEqual(@as(usize, 2), StickyLineCandidateProvider.updateIndex(2));
}
