// Port of `src/vs/editor/contrib/documentSymbols/test/browser/outlineModel.test.ts`.
//
// The browser test suite's cache/cancellation cases use `OutlineModelService`,
// which the terminal port does not have. The portable tree, duplicate-id and
// marker rollup cases are ported here; the terminal outline pane owns the
// debounce and rebuild lifecycle instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const languages = @import("../../../../common/languages.zig");
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const MarkerSeverity = @import("../../../../../platform/markers/common/markers.zig").MarkerSeverity;
const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;
const outline_model = @import("../../browser/outlineModel.zig");
const OutlineElement = outline_model.OutlineElement;
const OutlineGroup = outline_model.OutlineGroup;
const OutlineMarker = outline_model.OutlineMarker;
const OutlineModel = outline_model.OutlineModel;

test "OutlineModel: create compacts one provider and computes enclosing position" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor.createFromText(
        allocator,
        io,
        "class A {\n  method() {}\n}\n",
        "test.ts",
        60,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const Provider = struct {
        fn provide(_: *anyopaque, arena: Allocator, _: *TextModel, _: CancellationToken) anyerror![]const languages.DocumentSymbol {
            const method = languages.DocumentSymbol{
                .name = "method",
                .kind = 5,
                .range = Range.init(2, 3, 2, 14),
                .selection_range = Range.init(2, 9, 2, 15),
            };
            const methods = [_]languages.DocumentSymbol{method};
            const children = try arena.dupe(languages.DocumentSymbol, &methods);
            const class = [_]languages.DocumentSymbol{.{
                .name = "A",
                .kind = 4,
                .range = Range.init(1, 1, 3, 2),
                .selection_range = Range.init(1, 7, 1, 8),
                .children = children,
            }};
            return arena.dupe(languages.DocumentSymbol, &class);
        }
    };
    var context: u8 = 0;
    const provider = languages.DocumentSymbolProvider{
        .context = @ptrCast(&context),
        .display_name = "test",
        .provide_document_symbols = Provider.provide,
    };
    const outline = try OutlineModel.create(allocator, editor.model, provider);
    defer outline.deinit();

    try std.testing.expectEqual(@as(usize, 1), outline.roots.len);
    try std.testing.expectEqual(@as(usize, 1), outline.roots[0].children.len);
    try std.testing.expectEqualStrings("A", outline.roots[0].symbol.name);
    try std.testing.expectEqualStrings("root/provider_0/A", outline.roots[0].id);
    try std.testing.expectEqualStrings("root/provider_0/A/method", outline.roots[0].children[0].id);

    const chain = try outline.elementChain(allocator, Position.init(2, 10));
    defer allocator.free(chain);
    try std.testing.expectEqual(@as(usize, 2), chain.len);
    try std.testing.expectEqualStrings("method", chain[1].symbol.name);

    const enclosing = outline.getItemEnclosingPosition(Position.init(2, 10)).?;
    try std.testing.expectEqualStrings("method", enclosing.symbol.name);
    try std.testing.expect(outline.getItemEnclosingPosition(Position.init(9, 1)) == null);
}

test "OutlineModel: duplicate symbol ids fall back to the range" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor.createFromText(
        allocator,
        io,
        "foo\nfoo\n",
        "test.ts",
        60,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const Provider = struct {
        fn provide(_: *anyopaque, arena: Allocator, _: *TextModel, _: CancellationToken) anyerror![]const languages.DocumentSymbol {
            const symbols = [_]languages.DocumentSymbol{
                .{ .name = "foo", .kind = 12, .range = Range.init(1, 1, 1, 4), .selection_range = Range.init(1, 1, 1, 4) },
                .{ .name = "foo", .kind = 12, .range = Range.init(2, 1, 2, 4), .selection_range = Range.init(2, 1, 2, 4) },
            };
            return arena.dupe(languages.DocumentSymbol, &symbols);
        }
    };
    var context: u8 = 0;
    const provider = languages.DocumentSymbolProvider{
        .context = @ptrCast(&context),
        .provide_document_symbols = Provider.provide,
    };
    const outline = try OutlineModel.create(allocator, editor.model, provider);
    defer outline.deinit();

    try std.testing.expectEqualStrings("root/provider_0/foo", outline.roots[0].id);
    try std.testing.expectEqualStrings("root/provider_0/foo_2_1", outline.roots[1].id);
}

test "OutlineElement - updateMarker" {
    const allocator = std.testing.allocator;
    var e0 = OutlineElement{ .id = "foo1", .symbol = fakeSymbol(Range.init(1, 1, 1, 10)) };
    var e1 = OutlineElement{ .id = "foo2", .symbol = fakeSymbol(Range.init(2, 1, 5, 1)) };
    var e2 = OutlineElement{ .id = "foo3", .symbol = fakeSymbol(Range.init(6, 1, 10, 10)) };
    var children = [_]*OutlineElement{ &e0, &e1, &e2 };
    var group = OutlineGroup{ .id = "group", .children = children[0..] };
    var groups = [_]*OutlineGroup{&group};
    var model = OutlineModel{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .groups = groups[0..],
        .roots = children[0..],
    };
    defer model.arena.deinit();

    var markers = [_]OutlineMarker{
        .{ .range = Range.init(6, 1, 6, 7), .severity = MarkerSeverity.Error },
        .{ .range = Range.init(1, 1, 1, 4), .severity = MarkerSeverity.Error },
        .{ .range = Range.init(10, 2, 14, 1), .severity = MarkerSeverity.Error },
    };
    try model.updateMarker(&markers);
    try std.testing.expectEqual(@as(usize, 1), e0.marker.?.count);
    try std.testing.expect(e1.marker == null);
    try std.testing.expectEqual(@as(usize, 2), e2.marker.?.count);

    try model.updateMarker(&.{});
    try std.testing.expect(e0.marker == null);
    try std.testing.expect(e1.marker == null);
    try std.testing.expect(e2.marker == null);
}

test "OutlineElement - updateMarker rollup" {
    const allocator = std.testing.allocator;
    var c1 = OutlineElement{ .id = "A/B", .symbol = fakeSymbol(Range.init(2, 4, 5, 4)) };
    var c2 = OutlineElement{ .id = "A/C", .symbol = fakeSymbol(Range.init(6, 4, 9, 4)) };
    var parent_children = [_]*OutlineElement{ &c1, &c2 };
    var parent = OutlineElement{
        .id = "A",
        .symbol = fakeSymbol(Range.init(1, 1, 11, 1)),
        .children = parent_children[0..],
    };
    var roots = [_]*OutlineElement{&parent};
    var group = OutlineGroup{ .id = "group", .children = roots[0..] };
    var groups = [_]*OutlineGroup{&group};
    var model = OutlineModel{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .groups = groups[0..],
        .roots = roots[0..],
    };
    defer model.arena.deinit();

    var markers = [_]OutlineMarker{.{ .range = Range.init(2, 4, 5, 4), .severity = MarkerSeverity.Error }};
    try model.updateMarker(&markers);
    try std.testing.expectEqual(@as(usize, 0), parent.marker.?.count);
    try std.testing.expectEqual(@as(usize, 1), c1.marker.?.count);
    try std.testing.expect(c2.marker == null);

    var markers2 = [_]OutlineMarker{
        .{ .range = Range.init(2, 4, 5, 4), .severity = MarkerSeverity.Error },
        .{ .range = Range.init(2, 6, 2, 8), .severity = MarkerSeverity.Error },
        .{ .range = Range.init(7, 6, 7, 8), .severity = MarkerSeverity.Error },
    };
    try model.updateMarker(&markers2);
    try std.testing.expectEqual(@as(usize, 0), parent.marker.?.count);
    try std.testing.expectEqual(@as(usize, 2), c1.marker.?.count);
    try std.testing.expectEqual(@as(usize, 1), c2.marker.?.count);

    var markers3 = [_]OutlineMarker{
        .{ .range = Range.init(1, 4, 1, 11), .severity = MarkerSeverity.Warning },
        .{ .range = Range.init(7, 6, 7, 8), .severity = MarkerSeverity.Warning },
    };
    try model.updateMarker(&markers3);
    try std.testing.expectEqual(@as(usize, 1), parent.marker.?.count);
    try std.testing.expect(c1.marker == null);
    try std.testing.expectEqual(@as(usize, 1), c2.marker.?.count);
}

fn fakeSymbol(range: Range) languages.DocumentSymbol {
    return .{
        .name = "foo",
        .detail = "fake",
        .kind = 17,
        .range = range,
        .selection_range = range,
    };
}
