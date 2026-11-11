// Port of `src/vs/editor/contrib/hover/test/browser/contentHover.test.ts`.
//
// The upstream tests use `withTestCodeEditor` and a real view model. The TUI
// harness uses `Editor`/`TestModel`; the wrap case is expressed through the
// coordinates host, which is the same `startColumnBoundary` value the editor's
// view model supplies in the browser.
const std = @import("std");

const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const ModelDecoration = @import("../../../../common/model.zig").ModelDecoration;
const ModelDecorationOptions = @import("../../../../common/model.zig").ModelDecorationOptions;
const TrackedRangeStickiness = @import("../../../../common/model.zig").TrackedRangeStickiness;
const hoverTypes = @import("../../browser/hoverTypes.zig");
const IHoverPart = hoverTypes.IHoverPart;
const HoverAnchor = hoverTypes.HoverAnchor;
const HoverRangeAnchor = hoverTypes.HoverRangeAnchor;
const HoverCoordinatesHost = @import("../../browser/contentHoverRendered.zig").HoverCoordinatesHost;
const computeHoverPositions = @import("../../browser/contentHoverRendered.zig").computeHoverPositions;
const ContentHoverComputer = @import("../../browser/contentHoverComputer.zig").ContentHoverComputer;
const MarkdownHoverParticipant = @import("../../browser/markdownHoverParticipant.zig").MarkdownHoverParticipant;

const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;

fn validPart(range: Range) IHoverPart {
    return .{
        .owner = @ptrFromInt(1),
        .range = range,
        .is_valid_for_hover_anchor = struct {
            fn check(_: *const IHoverPart, _: *const HoverAnchor) bool {
                return true;
            }
        }.check,
    };
}

test "issue #151235: Gitlens hover shows up in the wrong place" {
    const testing = std.testing;
    const part = validPart(Range.init(4, 1, 5, 6));

    const positions = computeHoverPositions(null, Range.init(5, 5, 5, 5), &[_]IHoverPart{part});
    try testing.expectEqual(Position.init(5, 5), positions.show_at_position);
    try testing.expectEqual(Position.init(5, 5), positions.show_at_secondary_position);
}

test "issue #95328: Hover placement with word-wrap" {
    const testing = std.testing;

    const Host = struct {
        fn boundary(_: *anyopaque, _: Position) usize {
            return 6;
        }
    };
    var host_state: u8 = 0;
    const host = HoverCoordinatesHost{
        .context = &host_state,
        .model_column_at_view_line_start = Host.boundary,
    };

    const part = validPart(Range.init(1, 1, 1, 15));
    const positions = computeHoverPositions(host, Range.init(1, 8, 1, 8), &[_]IHoverPart{part});
    try testing.expectEqual(Position.init(1, 8), positions.show_at_position);
    try testing.expectEqual(Position.init(1, 6), positions.show_at_secondary_position);
}

test "markdown participant: line decoration hover messages become hover parts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try TestModel.init(allocator, "hello world", "nullLanguage");
    defer ctx.deinit();

    var options = ModelDecorationOptions.init("test.hover", .AlwaysGrowsWhenTypingAtEdges);
    options.hoverMessage = "**hello**";
    var decorations = [_]ModelDecoration{
        .{ .id = 1, .ownerId = 0, .range = Range.init(1, 1, 1, 6), .options = &options },
    };

    var participant = MarkdownHoverParticipant.init(allocator, ctx.model, &.{});
    defer participant.deinit();
    const iface = participant.interface();

    const anchor = HoverAnchor{ .range = HoverRangeAnchor.init(0, Range.init(1, 2, 1, 2)) };
    const parts = iface.compute_sync.?(iface.context, &anchor, &decorations, .mouse);
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expectEqual(@as(usize, 1), parts[0].range.startColumn);
    try testing.expectEqual(@as(usize, 6), parts[0].range.endColumn);
    try testing.expect(parts[0].isValidForHoverAnchor(&anchor));
}

test "markdown participant: provider hover uses the provider range" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try TestModel.init(allocator, "hello", "nullLanguage");
    defer ctx.deinit();

    const Provider = struct {
        contents: [1]@import("../../../../common/languages.zig").IMarkdownString = undefined,
        range: Range,

        fn provide(context: *anyopaque, _: *@import("../../../../common/model/textModel.zig").TextModel, _: Position, _: @import("../../../../../base/common/cancellation.zig").CancellationToken, _: ?*const @import("../../../../common/languages.zig").HoverContext) anyerror!?@import("../../../../common/languages.zig").Hover {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.contents[0] = .{ .value = "provider" };
            return .{ .contents = &self.contents, .range = self.range };
        }
    };
    var provider_state = Provider{ .range = Range.init(1, 2, 1, 4) };
    const providers = [_]@import("../../../../common/languages.zig").HoverProvider{.{
        .context = &provider_state,
        .provide_hover = Provider.provide,
    }};

    var participant = MarkdownHoverParticipant.init(allocator, ctx.model, &providers);
    defer participant.deinit();
    const iface = participant.interface();

    const anchor = HoverAnchor{ .range = HoverRangeAnchor.init(0, Range.init(1, 1, 1, 1)) };
    const parts = iface.compute_async.?(iface.context, &anchor, &.{}, .mouse, .None);
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expectEqual(@as(usize, 2), parts[0].range.startColumn);
    try testing.expectEqual(@as(usize, 4), parts[0].range.endColumn);
}

test "markdown participant: hover message part stays valid for a covering anchor" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try TestModel.init(allocator, "hello world", "nullLanguage");
    defer ctx.deinit();

    var options = ModelDecorationOptions.init("test.hover", .AlwaysGrowsWhenTypingAtEdges);
    options.hoverMessage = "message";
    var decorations = [_]ModelDecoration{
        .{ .id = 1, .ownerId = 0, .range = Range.init(1, 1, 1, 11), .options = &options },
    };

    var participant = MarkdownHoverParticipant.init(allocator, ctx.model, &.{});
    defer participant.deinit();
    const iface = participant.interface();

    var inside = HoverAnchor{ .range = HoverRangeAnchor.init(0, Range.init(1, 4, 1, 4)) };
    const parts = iface.compute_sync.?(iface.context, &inside, &decorations, .mouse);
    try testing.expectEqual(@as(usize, 1), parts.len);

    var outside = HoverAnchor{ .range = HoverRangeAnchor.init(0, Range.init(1, 12, 1, 12)) };
    try testing.expect(!parts[0].isValidForHoverAnchor(&outside));
}
