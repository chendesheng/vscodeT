// Port of `src/vs/editor/contrib/hover/browser/contentHoverComputer.ts`.
//
// Terminal adaptation: computations are synchronous callbacks. The computer
// owns a scratch arena for the parts of the current computation; the wrapper
// copies the part values before the next computation starts, so participant
// payloads only need to live until then.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const ModelDecoration = @import("../../../common/model.zig").ModelDecoration;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const hoverTypes = @import("./hoverTypes.zig");
const HoverAnchor = hoverTypes.HoverAnchor;
const HoverAnchorType = hoverTypes.HoverAnchorType;
const HoverStartSource = hoverTypes.HoverStartSource;
const IEditorHoverParticipant = hoverTypes.IEditorHoverParticipant;
const IHoverPart = hoverTypes.IHoverPart;

pub const ContentHoverComputerOptions = struct {
    should_focus: bool = false,
    anchor: HoverAnchor,
    source: HoverStartSource = .mouse,
    insist_on_keeping_hover_visible: bool = false,
};

pub const ContentHoverComputer = struct {
    model: *TextModel,
    participants: []const IEditorHoverParticipant,
    scratch: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator, model: *TextModel, participants: []const IEditorHoverParticipant) ContentHoverComputer {
        return .{
            .model = model,
            .participants = participants,
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *ContentHoverComputer) void {
        self.scratch.deinit();
    }

    /// Drops the previous computation's parts. Must be called before a new
    /// hover operation starts.
    pub fn beginComputation(self: *ContentHoverComputer) void {
        _ = self.scratch.reset(.retain_capacity);
    }

    fn getLineDecorations(self: *ContentHoverComputer, anchor: *const HoverAnchor) ![]ModelDecoration {
        const anchor_type = anchor.getType();
        const supports_marker_hover = switch (anchor.*) {
            .foreign_element => |foreign| foreign.supports_marker_hover orelse false,
            .range => true,
        };
        if (anchor_type != .range and !supports_marker_hover) return &.{};

        const range = anchor.getRange();
        const line_number = range.startLineNumber;
        if (line_number > self.model.getLineCount()) return &.{};

        const decorations = try self.model.getLineDecorations(line_number, 0, false);
        defer if (decorations.len > 0) self.model.getAllocator().free(decorations);
        const allocator = self.scratch.allocator();
        var result = ArrayList(ModelDecoration).init(allocator);

        const max_column = self.model.getLineMaxColumn(line_number);
        for (decorations) |decoration| {
            if (decoration.options.isWholeLine orelse false) {
                try result.append(decoration);
                continue;
            }
            const start_column = if (decoration.range.startLineNumber == line_number) decoration.range.startColumn else 1;
            const end_column = if (decoration.range.endLineNumber == line_number) decoration.range.endColumn else max_column;

            if (decoration.options.showIfCollapsed orelse false) {
                // Relax the check around `showIfCollapsed` decorations to also
                // include +/- 1 character, as upstream does.
                if (start_column > range.startColumn + 1 or range.endColumn - 1 > end_column) continue;
            } else {
                if (start_column > range.startColumn or range.endColumn > end_column) continue;
            }
            try result.append(decoration);
        }
        return try result.toOwnedSlice();
    }

    /// Upstream `computeAsync`: merges the async results of all participants.
    pub fn computeAsync(
        self: *ContentHoverComputer,
        options: ContentHoverComputerOptions,
        token: CancellationToken,
    ) ![]const IHoverPart {
        const line_decorations = try self.getLineDecorations(&options.anchor);
        var result = ArrayList(IHoverPart).init(self.scratch.allocator());
        for (self.participants) |participant| {
            const compute = participant.compute_async orelse continue;
            const parts = compute(participant.context, &options.anchor, line_decorations, options.source, token);
            try result.appendSlice(parts);
        }
        return try result.toOwnedSlice();
    }

    /// Upstream `computeSync`: concatenates the synchronous results. Providers
    /// are coalesced; the terminal path has no nullable slots.
    pub fn computeSync(self: *ContentHoverComputer, options: ContentHoverComputerOptions) ![]const IHoverPart {
        const line_decorations = try self.getLineDecorations(&options.anchor);
        var result = ArrayList(IHoverPart).init(self.scratch.allocator());
        for (self.participants) |participant| {
            const compute = participant.compute_sync orelse continue;
            const parts = compute(participant.context, &options.anchor, line_decorations, options.source);
            try result.appendSlice(parts);
        }
        return try result.toOwnedSlice();
    }
};

test "contentHoverComputer: merges participant results" {
    const testing = std.testing;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    const Range = @import("../../../common/core/range.zig").Range;

    const Participant = struct {
        part: [1]IHoverPart,

        fn compute(context: *anyopaque, anchor: *const HoverAnchor, decorations: []const ModelDecoration, source: HoverStartSource) []const IHoverPart {
            _ = anchor;
            _ = decorations;
            _ = source;
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.part[0..];
        }
    };

    const Valid = struct {
        fn check(_: *const IHoverPart, _: *const HoverAnchor) bool {
            return true;
        }
    };

    const allocator = testing.allocator;
    var ctx = try TestModel.init(allocator, "hello", "nullLanguage");
    defer ctx.deinit();

    var participant_state = Participant{
        .part = .{.{
            .owner = @ptrFromInt(1),
            .range = Range.init(1, 1, 1, 3),
            .is_valid_for_hover_anchor = Valid.check,
        }},
    };
    const participants = [_]IEditorHoverParticipant{.{
        .context = &participant_state,
        .hover_ordinal = 1,
        .compute_sync = Participant.compute,
    }};

    var computer = ContentHoverComputer.init(allocator, ctx.model, &participants);
    defer computer.deinit();
    computer.beginComputation();

    const parts = try computer.computeSync(.{
        .anchor = .{ .range = hoverTypes.HoverRangeAnchor.init(1, Range.init(1, 1, 1, 2)) },
    });
    try testing.expectEqual(@as(usize, 1), parts.len);
}
