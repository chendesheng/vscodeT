// Port of the synchronous computation from
// `src/vs/editor/contrib/hover/browser/contentHoverComputer.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const ModelDecoration = @import("../../../common/model.zig").ModelDecoration;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const hoverTypes = @import("./hoverTypes.zig");
const HoverAnchor = hoverTypes.HoverAnchor;
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

    pub fn init(model: *TextModel, participants: []const IEditorHoverParticipant) ContentHoverComputer {
        return .{ .model = model, .participants = participants };
    }

    fn getLineDecorations(self: *ContentHoverComputer, anchor: *const HoverAnchor) ![]ModelDecoration {
        if (anchor.* == .range and false) return &[_]ModelDecoration{};
        const range = anchor.getRange();
        const line_number = range.startLineNumber;
        if (line_number > self.model.getLineCount()) return &[_]ModelDecoration{};

        const decorations = try self.model.getLineDecorations(line_number, 0, false);
        var result = ArrayList(ModelDecoration).init(self.model.getAllocator());
        errdefer result.deinit();

        const max_column = self.model.getLineMaxColumn(line_number);
        for (decorations) |decoration| {
            if (decoration.options.isWholeLine orelse false) {
                try result.append(decoration);
                continue;
            }
            const start_column = if (decoration.range.startLineNumber == line_number) decoration.range.startColumn else 1;
            const end_column = if (decoration.range.endLineNumber == line_number) decoration.range.endColumn else max_column;

            if (decoration.options.showIfCollapsed orelse false) {
                if (start_column > range.startColumn + 1 or range.endColumn - 1 > end_column) continue;
            } else {
                if (start_column > range.startColumn or range.endColumn > end_column) continue;
            }
            try result.append(decoration);
        }
        return try result.toOwnedSlice();
    }

    pub fn computeSync(self: *ContentHoverComputer, allocator: Allocator, options: ContentHoverComputerOptions) ![]IHoverPart {
        const decorations = try self.getLineDecorations(&options.anchor);
        defer allocator.free(decorations);

        var result = ArrayList(IHoverPart).init(allocator);
        errdefer result.deinit();
        for (self.participants) |participant| {
            const compute = participant.compute_sync orelse continue;
            const parts = compute(participant.context, &options.anchor, decorations, options.source);
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
        fn check(_: *const anyopaque, _: *const HoverAnchor) bool {
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

    var computer = ContentHoverComputer.init(ctx.model, &participants);
    const parts = try computer.computeSync(allocator, .{
        .anchor = .{ .range = hoverTypes.HoverRangeAnchor.init(1, Range.init(1, 1, 1, 2)) },
    });
    defer allocator.free(parts);
    try testing.expectEqual(@as(usize, 1), parts.len);
}
