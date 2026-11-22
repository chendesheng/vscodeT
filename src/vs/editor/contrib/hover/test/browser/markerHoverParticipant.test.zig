// Port of `src/vs/editor/contrib/hover/test/browser/markerHoverParticipant.test.ts`.
//
// Terminal adaptation: the upstream tests inspect DOM nodes. Here the rendered
// rows are painted into a `ui.CellGrid` and read back as text. The marker
// model has no `relatedInformation`, so that case is reduced to the multiline
// message plus source/code assertion.
const std = @import("std");

const ui = @import("ui");

const Range = @import("../../../../common/core/range.zig").Range;
const ModelDecorationOptions = @import("../../../../common/model.zig").ModelDecorationOptions;
const MarkerService = @import("../../../../../platform/markers/common/markerService.zig").MarkerService;
const markers = @import("../../../../../platform/markers/common/markers.zig");
const MarkerDecorationsService = @import("../../../../common/services/markerDecorationsService.zig").MarkerDecorationsService;
const hoverTypes = @import("../../browser/hoverTypes.zig");
const MarkerHover = @import("../../browser/markerHoverParticipant.zig").MarkerHover;
const MarkerHoverParticipant = @import("../../browser/markerHoverParticipant.zig").MarkerHoverParticipant;
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;

const DummyStatusBar = struct {
    fn addAction(_: *anyopaque, _: hoverTypes.HoverActionOptions) hoverTypes.IEditorHoverAction {
        return .{ .context = undefined, .set_enabled = setEnabled };
    }
    fn setEnabled(_: *anyopaque, _: bool) void {}
    fn hasContent(_: *anyopaque) bool {
        return false;
    }
    fn append(_: *anyopaque, _: *ui.Node) void {}
};

fn noop(_: *anyopaque) void {}
fn noopDimensions(_: *anyopaque, _: usize, _: usize) void {}

var dummy_status_bar: hoverTypes.IEditorHoverStatusBar = .{
    .context = undefined,
    .add_action = DummyStatusBar.addAction,
    .has_content = DummyStatusBar.hasContent,
    .append = DummyStatusBar.append,
};

fn renderContext() hoverTypes.IEditorHoverRenderContext {
    // The marker participant renders the rows directly and does not use the
    // status bar.
    return .{
        .context = undefined,
        .fragment = null,
        .status_bar = &dummy_status_bar,
        .hide = noop,
        .on_contents_changed = noop,
        .set_minimum_dimensions = noopDimensions,
        .focus = noop,
    };
}

fn validForAnchor(part: *const hoverTypes.IHoverPart, anchor: *const hoverTypes.HoverAnchor) bool {
    if (anchor.getType() != .range) return false;
    const range = anchor.getRange();
    return part.range.startColumn <= range.startColumn and
        part.range.endColumn >= range.endColumn;
}

fn makePart(owner: *MarkerHoverParticipant, hover: *MarkerHover) hoverTypes.IHoverPart {
    return .{
        .owner = owner,
        .range = hover.range,
        .data = hover,
        .is_valid_for_hover_anchor = validForAnchor,
    };
}

test "marker hover: renders diagnostics by severity without changing input order" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var participant = MarkerHoverParticipant.init(allocator, undefined, null);
    defer participant.deinit();

    var hovers = [_]MarkerHover{
        .{ .range = Range.init(1, 10, 1, 15), .severity = markers.MarkerSeverity.Hint, .message = "Hint diagnostic" },
        .{ .range = Range.init(1, 10, 1, 15), .severity = markers.MarkerSeverity.Info, .message = "Info diagnostic" },
        .{ .range = Range.init(1, 10, 1, 15), .severity = markers.MarkerSeverity.Warning, .message = "First warning" },
        .{ .range = Range.init(1, 12, 1, 15), .severity = markers.MarkerSeverity.Warning, .message = "Second warning" },
        .{ .range = Range.init(1, 14, 1, 15), .severity = markers.MarkerSeverity.Error, .message = "Expected to find )" },
    };
    var parts: [hovers.len]hoverTypes.IHoverPart = undefined;
    for (&parts, 0..) |*part, index| part.* = makePart(&participant, &hovers[index]);
    const original_order = parts;

    const interface = participant.interface();
    const context = renderContext();
    const rendered = try interface.render_hover_parts.?(interface.context, &context, &parts);
    try testing.expectEqual(@as(usize, 5), rendered.len);

    const expected = [_][]const u8{
        "Error: Expected to find )",
        "Warning: First warning",
        "Warning: Second warning",
        "Info: Info diagnostic",
        "Hint: Hint diagnostic",
    };
    for (rendered, 0..) |part, index| {
        try testing.expectEqualStrings(expected[index], interface.get_accessible_content.?(interface.context, &part.hover_part));
    }
    // Rendering sorts a copy of the part list, matching upstream.
    for (&parts, original_order) |part, original| {
        try testing.expectEqual(original.data, part.data);
        try testing.expectEqual(original.range.startColumn, part.range.startColumn);
        try testing.expectEqual(original.range.endColumn, part.range.endColumn);
    }
}

test "marker hover: multiline message, source and code render as rows" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var participant = MarkerHoverParticipant.init(allocator, undefined, null);
    defer participant.deinit();

    var hover = MarkerHover{
        .range = Range.init(1, 1, 1, 5),
        .severity = markers.MarkerSeverity.Warning,
        .message = "First line\nSecond line",
        .source = "test-source",
        .code = "test-code",
    };
    var part = makePart(&participant, &hover);
    const interface = participant.interface();
    const context = renderContext();
    const rendered = try interface.render_hover_parts.?(interface.context, &context, &[1]hoverTypes.IHoverPart{part});
    try testing.expectEqual(@as(usize, 1), rendered.len);

    var doc = try ui.Document.init(allocator, .{ .cols = 60, .rows = 8 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{ .position = .absolute, .width = .{ .percent = 100 }, .height = .{ .percent = 100 } });
    doc.setRoot(root);

    const rendered_part = rendered[0];
    _ = try rendered_part.build(rendered_part.context, &doc, root, 40, 0);
    var grid = try ui.CellGrid.init(allocator, 60, 8);
    defer grid.deinit();
    try ui.paint.paintDocument(&doc, &grid);

    const row0 = try grid.rowText(allocator, 0);
    defer allocator.free(row0);
    const row1 = try grid.rowText(allocator, 1);
    defer allocator.free(row1);
    const row2 = try grid.rowText(allocator, 2);
    defer allocator.free(row2);
    try testing.expect(std.mem.indexOf(u8, row0, "First line") != null);
    try testing.expect(std.mem.indexOf(u8, row1, "Second line") != null);
    try testing.expect(std.mem.indexOf(u8, row2, "test-source(test-code)") != null);
    try testing.expectEqualStrings("Warning: First line\nSecond line", interface.get_accessible_content.?(interface.context, &part));
}

test "marker hover: marker decorations resolve to hover parts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var model = try TestModel.init(allocator, "some text", "plaintext");
    defer model.deinit();
    var marker_service = MarkerService.init(allocator);
    defer marker_service.deinit();
    const service = try MarkerDecorationsService.init(allocator, &marker_service);
    defer service.deinit();
    try service.registerModel(model.model);

    const resource = try markers.Resource.fromUri(allocator, model.model.uri());
    defer {
        var owned = resource;
        owned.deinit(allocator);
    }
    try marker_service.changeOne("test", resource, &.{
        .{
            .message = "Problem",
            .source = "test-source",
            .severity = markers.MarkerSeverity.Error,
            .start_line_number = 1,
            .start_column = 1,
            .end_line_number = 1,
            .end_column = 5,
        },
    }, null);

    const decorations = try model.model.getLineDecorations(1, 0, false);
    defer model.model.getAllocator().free(decorations);

    var participant = MarkerHoverParticipant.init(allocator, model.model, service);
    defer participant.deinit();
    const interface = participant.interface();
    var anchor = hoverTypes.HoverAnchor{ .range = hoverTypes.HoverRangeAnchor.init(0, Range.init(1, 2, 1, 2)) };
    const parts = interface.compute_sync.?(interface.context, &anchor, decorations, .mouse);
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expectEqual(@as(usize, 1), parts[0].range.startColumn);
    try testing.expectEqual(@as(usize, 5), parts[0].range.endColumn);
    const hover: *const MarkerHover = @ptrCast(@alignCast(parts[0].data.?));
    try testing.expectEqualStrings("Problem", hover.message);
    try testing.expectEqualStrings("test-source", hover.source.?);
    try testing.expect(parts[0].isValidForHoverAnchor(&anchor));

    var outside = hoverTypes.HoverAnchor{ .range = hoverTypes.HoverRangeAnchor.init(0, Range.init(1, 6, 1, 6)) };
    try testing.expect(!parts[0].isValidForHoverAnchor(&outside));
}

test "marker hover: marker decorations without markers are ignored" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var model = try TestModel.init(allocator, "some text", "plaintext");
    defer model.deinit();
    var marker_service = MarkerService.init(allocator);
    defer marker_service.deinit();
    const service = try MarkerDecorationsService.init(allocator, &marker_service);
    defer service.deinit();
    try service.registerModel(model.model);

    var options = ModelDecorationOptions.init("not a marker", .AlwaysGrowsWhenTypingAtEdges);
    options.className = "line-insert";
    const delta = [_]@import("../../../../common/model.zig").ModelDeltaDecoration{.{
        .range = Range.init(1, 1, 1, 5),
        .options = &options,
    }};
    const ids = try model.model.deltaDecorations(&.{}, &delta, 0);
    defer allocator.free(ids);
    const decorations = try model.model.getLineDecorations(1, 0, false);
    defer model.model.getAllocator().free(decorations);

    var participant = MarkerHoverParticipant.init(allocator, model.model, service);
    defer participant.deinit();
    const interface = participant.interface();
    var anchor = hoverTypes.HoverAnchor{ .range = hoverTypes.HoverRangeAnchor.init(0, Range.init(1, 2, 1, 2)) };
    const parts = interface.compute_sync.?(interface.context, &anchor, decorations, .mouse);
    try testing.expectEqual(@as(usize, 0), parts.len);
}
