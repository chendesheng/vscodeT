// Port of `src/vs/editor/contrib/gotoSymbol/test/browser/referencesModel.test.ts`.
const std = @import("std");
const references_model = @import("../../browser/referencesModel.zig");
const ReferencesModel = references_model.ReferencesModel;
const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const LocationLink = @import("../../../../common/languages.zig").LocationLink;

fn link(uri: []const u8, range: Range) LocationLink {
    return .{
        .uri = uri,
        .range = range,
        .target_selection_range = range,
    };
}

test "references: nearestReference" {
    const links = [_]LocationLink{
        link("file:///out/obj/can", Range.init(1, 1, 1, 1)),
        link("file:///out/obj/can2", Range.init(1, 1, 1, 1)),
        link("file:///src/can", Range.init(1, 1, 1, 1)),
    };
    var model = try ReferencesModel.init(std.testing.allocator, &links, "FOO");
    defer model.deinit();

    try std.testing.expectEqualStrings("file:///src/can", model.nearestReference("file:///src/can", Position.init(1, 1)).?.uri());
    try std.testing.expectEqualStrings("file:///src/can", model.nearestReference("file:///src/someOtherFileInSrc", Position.init(1, 1)).?.uri());
    try std.testing.expectEqualStrings("file:///out/obj/can", model.nearestReference("file:///out/someOtherFile", Position.init(1, 1)).?.uri());
    try std.testing.expectEqualStrings("file:///out/obj/can2", model.nearestReference("file:///out/obj/can2222", Position.init(1, 1)).?.uri());
}

test "references: groups, sort, dedup and provider-first" {
    const links = [_]LocationLink{
        link("file:///b", Range.init(3, 1, 3, 4)),
        link("file:///a", Range.init(2, 1, 2, 4)),
        link("file:///a", Range.init(2, 1, 2, 4)),
        link("file:///a", Range.init(1, 1, 1, 4)),
        link("file:///b", Range.init(1, 1, 1, 4)),
    };
    var model = try ReferencesModel.init(std.testing.allocator, &links, "References");
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 2), model.groups.len);
    try std.testing.expectEqual(@as(usize, 4), model.references.len);
    try std.testing.expectEqualStrings("file:///a", model.groups[0].uri);
    try std.testing.expectEqual(@as(usize, 2), model.groups[0].children.len);
    try std.testing.expectEqualStrings("file:///b", model.groups[1].uri);
    try std.testing.expectEqual(@as(usize, 2), model.groups[1].children.len);
    try std.testing.expectEqual(@as(usize, 1), model.groups[0].children[0].range().startLineNumber);
    try std.testing.expectEqual(@as(usize, 2), model.groups[0].children[1].range().startLineNumber);

    // The first input link is the provider-first reference even after sorting.
    try std.testing.expectEqualStrings("file:///b", model.firstReference().?.uri());
    try std.testing.expectEqual(@as(usize, 3), model.firstReference().?.range().startLineNumber);
}

test "references: referenceAt and cycling" {
    const links = [_]LocationLink{
        link("file:///a", Range.init(1, 2, 1, 6)),
        link("file:///a", Range.init(2, 2, 2, 6)),
        link("file:///b", Range.init(1, 2, 1, 6)),
    };
    var model = try ReferencesModel.init(std.testing.allocator, &links, "References");
    defer model.deinit();

    try std.testing.expectEqualStrings("file:///a", model.referenceAt("file:///a", Position.init(1, 3)).?.uri());
    try std.testing.expectEqual(@as(?*const references_model.OneReference, null), model.referenceAt("file:///a", Position.init(3, 1)));

    const first = &model.references[0];
    const second = model.nextOrPreviousReference(first, true);
    try std.testing.expectEqualStrings("file:///a", second.uri());
    try std.testing.expectEqual(@as(usize, 2), second.range().startLineNumber);
    const third = model.nextOrPreviousReference(second, true);
    try std.testing.expectEqualStrings("file:///b", third.uri());
    const wrapped = model.nextOrPreviousReference(third, true);
    try std.testing.expectEqualStrings("file:///a", wrapped.uri());
    const previous = model.nextOrPreviousReference(first, false);
    try std.testing.expectEqualStrings("file:///b", previous.uri());
}

test "references: empty model" {
    const links = [_]LocationLink{};
    var model = try ReferencesModel.init(std.testing.allocator, &links, "References");
    defer model.deinit();
    try std.testing.expect(model.isEmpty());
    try std.testing.expectEqual(@as(?*const references_model.OneReference, null), model.firstReference());
    try std.testing.expectEqual(@as(?*const references_model.OneReference, null), model.nearestReference("file:///a", Position.init(1, 1)));
}
