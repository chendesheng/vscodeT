// Port of `src/vs/workbench/contrib/scm/test/browser/scmHistory.test.ts`.
//
// All upstream `toISCMHistoryItemViewModelArray` cases and assertions are
// ported verbatim and in the same order. The upstream test inputs are plain
// JS objects; here they are built with `toSCMHistoryItem`, which copies the
// ids, parent ids and references into a per-test arena. The arena also owns
// the returned view models, so no manual frees are needed.
//
// The last four tests are terminal additions: they pin the glyph cells
// rasterized by `renderSCMHistoryItemGraph` / `renderSCMHistoryGraphPlaceholder`
// (upstream asserts SVG element structure instead).
const std = @import("std");

const history = @import("../../common/history.zig");
const scmHistory = @import("../../browser/scmHistory.zig");

const testing = std.testing;

fn toSCMHistoryItem(
    arena: *std.heap.ArenaAllocator,
    id: []const u8,
    parent_ids: []const []const u8,
    references: []const history.ISCMHistoryItemRef,
) !history.ISCMHistoryItem {
    const allocator = arena.allocator();

    const parent_ids_copy = try allocator.alloc([]const u8, parent_ids.len);
    for (parent_ids, 0..) |parent_id, index| {
        parent_ids_copy[index] = try allocator.dupe(u8, parent_id);
    }

    const references_copy = try allocator.alloc(history.ISCMHistoryItemRef, references.len);
    for (references, 0..) |reference, index| {
        references_copy[index] = try reference.clone(allocator);
    }

    return .{
        .id = try allocator.dupe(u8, id),
        .parent_ids = parent_ids_copy,
        .subject = "",
        .message = "",
        .references = references_copy,
    };
}

test "toISCMHistoryItemViewModelArray: empty graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &.{},
        null,
        null,
        null,
        null,
        false,
        false,
        null,
    );

    try testing.expectEqual(@as(usize, 0), view_models.len);
}

test "toISCMHistoryItemViewModelArray: single commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{}, &.{}),
    };

    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        null,
        null,
        null,
        null,
        false,
        false,
        null,
    );

    try testing.expectEqual(@as(usize, 1), view_models.len);

    try testing.expectEqual(@as(usize, 0), view_models[0].input_swimlanes.len);
    try testing.expectEqual(@as(usize, 0), view_models[0].output_swimlanes.len);
}

test "toISCMHistoryItemViewModelArray: linear graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{"b"}, &.{}),
        try toSCMHistoryItem(&arena, "b", &.{"c"}, &.{}),
        try toSCMHistoryItem(&arena, "c", &.{"d"}, &.{}),
        try toSCMHistoryItem(&arena, "d", &.{"e"}, &.{}),
        try toSCMHistoryItem(&arena, "e", &.{}, &.{}),
    };

    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        null,
        null,
        null,
        null,
        false,
        false,
        null,
    );

    try testing.expectEqual(@as(usize, 5), view_models.len);

    // node a
    try testing.expectEqual(@as(usize, 0), view_models[0].input_swimlanes.len);

    try testing.expectEqual(@as(usize, 1), view_models[0].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[0].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[0].output_swimlanes[0].color);

    // node b
    try testing.expectEqual(@as(usize, 1), view_models[1].input_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[1].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[1].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[1].output_swimlanes.len);
    try testing.expectEqualStrings("c", view_models[1].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[1].output_swimlanes[0].color);

    // node c
    try testing.expectEqual(@as(usize, 1), view_models[2].input_swimlanes.len);
    try testing.expectEqualStrings("c", view_models[2].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[2].output_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[2].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].output_swimlanes[0].color);

    // node d
    try testing.expectEqual(@as(usize, 1), view_models[3].input_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[3].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[3].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].output_swimlanes[0].color);

    // node e
    try testing.expectEqual(@as(usize, 1), view_models[4].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[4].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[4].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 0), view_models[4].output_swimlanes.len);
}

test "toISCMHistoryItemViewModelArray: merge commit (single commit in topic branch)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{"b"}, &.{}),
        try toSCMHistoryItem(&arena, "b", &.{ "c", "d" }, &.{}),
        try toSCMHistoryItem(&arena, "d", &.{"c"}, &.{}),
        try toSCMHistoryItem(&arena, "c", &.{"e"}, &.{}),
        try toSCMHistoryItem(&arena, "e", &.{"f"}, &.{}),
    };

    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        null,
        null,
        null,
        null,
        false,
        false,
        null,
    );

    try testing.expectEqual(@as(usize, 5), view_models.len);

    // node a
    try testing.expectEqual(@as(usize, 0), view_models[0].input_swimlanes.len);

    try testing.expectEqual(@as(usize, 1), view_models[0].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[0].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[0].output_swimlanes[0].color);

    // node b
    try testing.expectEqual(@as(usize, 1), view_models[1].input_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[1].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[1].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 2), view_models[1].output_swimlanes.len);
    try testing.expectEqualStrings("c", view_models[1].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[1].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[1].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[1].output_swimlanes[1].color);

    // node d
    try testing.expectEqual(@as(usize, 2), view_models[2].input_swimlanes.len);
    try testing.expectEqualStrings("c", view_models[2].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[2].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[2].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[2].output_swimlanes.len);
    try testing.expectEqualStrings("c", view_models[2].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].output_swimlanes[0].color);
    try testing.expectEqualStrings("c", view_models[2].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[2].output_swimlanes[1].color);

    // node c
    try testing.expectEqual(@as(usize, 2), view_models[3].input_swimlanes.len);
    try testing.expectEqualStrings("c", view_models[3].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].input_swimlanes[0].color);
    try testing.expectEqualStrings("c", view_models[3].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[3].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 1), view_models[3].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].output_swimlanes[0].color);

    // node e
    try testing.expectEqual(@as(usize, 1), view_models[4].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[4].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[4].input_swimlanes[0].color);
    try testing.expectEqual(@as(usize, 1), view_models[4].output_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[4].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[4].output_swimlanes[0].color);
}

test "toISCMHistoryItemViewModelArray: merge commit (multiple commits in topic branch)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{ "b", "c" }, &.{}),
        try toSCMHistoryItem(&arena, "c", &.{"d"}, &.{}),
        try toSCMHistoryItem(&arena, "b", &.{"e"}, &.{}),
        try toSCMHistoryItem(&arena, "e", &.{"f"}, &.{}),
        try toSCMHistoryItem(&arena, "f", &.{"d"}, &.{}),
        try toSCMHistoryItem(&arena, "d", &.{"g"}, &.{}),
    };

    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        null,
        null,
        null,
        null,
        false,
        false,
        null,
    );

    try testing.expectEqual(@as(usize, 6), view_models.len);

    // node a
    try testing.expectEqual(@as(usize, 0), view_models[0].input_swimlanes.len);

    try testing.expectEqual(@as(usize, 2), view_models[0].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[0].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[0].output_swimlanes[0].color);
    try testing.expectEqualStrings("c", view_models[0].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[0].output_swimlanes[1].color);

    // node c
    try testing.expectEqual(@as(usize, 2), view_models[1].input_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[1].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[1].input_swimlanes[0].color);
    try testing.expectEqualStrings("c", view_models[1].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[1].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[1].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[1].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[1].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[1].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[1].output_swimlanes[1].color);

    // node b
    try testing.expectEqual(@as(usize, 2), view_models[2].input_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[2].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[2].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[2].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[2].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[2].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[2].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[2].output_swimlanes[1].color);

    // node e
    try testing.expectEqual(@as(usize, 2), view_models[3].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[3].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[3].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[3].output_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[3].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[3].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[3].output_swimlanes[1].color);

    // node f
    try testing.expectEqual(@as(usize, 2), view_models[4].input_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[4].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[4].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[4].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[4].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[4].output_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[4].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[4].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[4].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[4].output_swimlanes[1].color);

    // node d
    try testing.expectEqual(@as(usize, 2), view_models[5].input_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[5].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[5].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[5].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[5].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 1), view_models[5].output_swimlanes.len);
    try testing.expectEqualStrings("g", view_models[5].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[5].output_swimlanes[0].color);
}

test "toISCMHistoryItemViewModelArray: create brach from merge commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{ "b", "c" }, &.{}),
        try toSCMHistoryItem(&arena, "c", &.{"b"}, &.{}),
        try toSCMHistoryItem(&arena, "b", &.{ "d", "e" }, &.{}),
        try toSCMHistoryItem(&arena, "e", &.{"f"}, &.{}),
        try toSCMHistoryItem(&arena, "f", &.{"g"}, &.{}),
        try toSCMHistoryItem(&arena, "d", &.{"h"}, &.{}),
    };

    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        null,
        null,
        null,
        null,
        false,
        false,
        null,
    );

    try testing.expectEqual(@as(usize, 6), view_models.len);

    // node a
    try testing.expectEqual(@as(usize, 0), view_models[0].input_swimlanes.len);

    try testing.expectEqual(@as(usize, 2), view_models[0].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[0].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[0].output_swimlanes[0].color);
    try testing.expectEqualStrings("c", view_models[0].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[0].output_swimlanes[1].color);

    // node c
    try testing.expectEqual(@as(usize, 2), view_models[1].input_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[1].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[1].input_swimlanes[0].color);
    try testing.expectEqualStrings("c", view_models[1].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[1].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[1].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[1].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[1].output_swimlanes[0].color);
    try testing.expectEqualStrings("b", view_models[1].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[1].output_swimlanes[1].color);

    // node b
    try testing.expectEqual(@as(usize, 2), view_models[2].input_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[2].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].input_swimlanes[0].color);
    try testing.expectEqualStrings("b", view_models[2].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[2].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[2].output_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[2].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].output_swimlanes[0].color);
    try testing.expectEqualStrings("e", view_models[2].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[2].output_swimlanes[1].color);

    // node e
    try testing.expectEqual(@as(usize, 2), view_models[3].input_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[3].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].input_swimlanes[0].color);
    try testing.expectEqualStrings("e", view_models[3].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[3].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[3].output_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[3].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].output_swimlanes[0].color);
    try testing.expectEqualStrings("f", view_models[3].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[3].output_swimlanes[1].color);

    // node f
    try testing.expectEqual(@as(usize, 2), view_models[4].input_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[4].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[4].input_swimlanes[0].color);
    try testing.expectEqualStrings("f", view_models[4].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[4].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[4].output_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[4].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[4].output_swimlanes[0].color);
    try testing.expectEqualStrings("g", view_models[4].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[4].output_swimlanes[1].color);

    // node d
    try testing.expectEqual(@as(usize, 2), view_models[5].input_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[5].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[5].input_swimlanes[0].color);
    try testing.expectEqualStrings("g", view_models[5].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[5].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[5].output_swimlanes.len);
    try testing.expectEqualStrings("h", view_models[5].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[5].output_swimlanes[0].color);
    try testing.expectEqualStrings("g", view_models[5].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[5].output_swimlanes[1].color);
}

test "toISCMHistoryItemViewModelArray: create multiple branches from a commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{ "b", "c" }, &.{}),
        try toSCMHistoryItem(&arena, "c", &.{"d"}, &.{}),
        try toSCMHistoryItem(&arena, "b", &.{ "e", "f" }, &.{}),
        try toSCMHistoryItem(&arena, "f", &.{"g"}, &.{}),
        try toSCMHistoryItem(&arena, "e", &.{"g"}, &.{}),
        try toSCMHistoryItem(&arena, "d", &.{"g"}, &.{}),
        try toSCMHistoryItem(&arena, "g", &.{"h"}, &.{}),
    };

    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        null,
        null,
        null,
        null,
        false,
        false,
        null,
    );

    try testing.expectEqual(@as(usize, 7), view_models.len);

    // node a
    try testing.expectEqual(@as(usize, 0), view_models[0].input_swimlanes.len);

    try testing.expectEqual(@as(usize, 2), view_models[0].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[0].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[0].output_swimlanes[0].color);
    try testing.expectEqualStrings("c", view_models[0].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[0].output_swimlanes[1].color);

    // node c
    try testing.expectEqual(@as(usize, 2), view_models[1].input_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[1].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[1].input_swimlanes[0].color);
    try testing.expectEqualStrings("c", view_models[1].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[1].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[1].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[1].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[1].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[1].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[1].output_swimlanes[1].color);

    // node b
    try testing.expectEqual(@as(usize, 2), view_models[2].input_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[2].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[2].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[2].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 3), view_models[2].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[2].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[2].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[2].output_swimlanes[1].color);
    try testing.expectEqualStrings("f", view_models[2].output_swimlanes[2].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[2].output_swimlanes[2].color);

    // node f
    try testing.expectEqual(@as(usize, 3), view_models[3].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[3].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[3].input_swimlanes[1].color);
    try testing.expectEqualStrings("f", view_models[3].input_swimlanes[2].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[3].input_swimlanes[2].color);

    try testing.expectEqual(@as(usize, 3), view_models[3].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[3].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[3].output_swimlanes[1].color);
    try testing.expectEqualStrings("g", view_models[3].output_swimlanes[2].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[3].output_swimlanes[2].color);

    // node e
    try testing.expectEqual(@as(usize, 3), view_models[4].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[4].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[4].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[4].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[4].input_swimlanes[1].color);
    try testing.expectEqualStrings("g", view_models[4].input_swimlanes[2].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[4].input_swimlanes[2].color);

    try testing.expectEqual(@as(usize, 3), view_models[4].output_swimlanes.len);
    try testing.expectEqualStrings("g", view_models[4].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[4].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[4].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[4].output_swimlanes[1].color);
    try testing.expectEqualStrings("g", view_models[4].output_swimlanes[2].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[4].output_swimlanes[2].color);

    // node d
    try testing.expectEqual(@as(usize, 3), view_models[5].input_swimlanes.len);
    try testing.expectEqualStrings("g", view_models[5].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[5].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[5].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[5].input_swimlanes[1].color);
    try testing.expectEqualStrings("g", view_models[5].input_swimlanes[2].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[5].input_swimlanes[2].color);

    try testing.expectEqual(@as(usize, 3), view_models[5].output_swimlanes.len);
    try testing.expectEqualStrings("g", view_models[5].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[5].output_swimlanes[0].color);
    try testing.expectEqualStrings("g", view_models[5].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[5].output_swimlanes[1].color);
    try testing.expectEqualStrings("g", view_models[5].output_swimlanes[2].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[5].output_swimlanes[2].color);

    // node g
    try testing.expectEqual(@as(usize, 3), view_models[6].input_swimlanes.len);
    try testing.expectEqualStrings("g", view_models[6].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[6].input_swimlanes[0].color);
    try testing.expectEqualStrings("g", view_models[6].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[1], view_models[6].input_swimlanes[1].color);
    try testing.expectEqualStrings("g", view_models[6].input_swimlanes[2].id);
    try testing.expectEqualStrings(scmHistory.color_registry[2], view_models[6].input_swimlanes[2].color);

    try testing.expectEqual(@as(usize, 1), view_models[6].output_swimlanes.len);
    try testing.expectEqualStrings("h", view_models[6].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[6].output_swimlanes[0].color);
}

test "toISCMHistoryItemViewModelArray: graph with color map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{"b"}, &.{.{ .id = "topic", .name = "topic" }}),
        try toSCMHistoryItem(&arena, "b", &.{"c"}, &.{}),
        try toSCMHistoryItem(&arena, "c", &.{"d"}, &.{.{ .id = "origin/topic", .name = "origin/topic" }}),
        try toSCMHistoryItem(&arena, "d", &.{"e"}, &.{}),
        try toSCMHistoryItem(&arena, "e", &.{ "f", "g" }, &.{}),
        try toSCMHistoryItem(&arena, "g", &.{"h"}, &.{.{ .id = "origin/main", .name = "origin/main" }}),
    };

    var color_map = scmHistory.ColorMap.init(allocator);
    try color_map.put("topic", scmHistory.history_item_ref_color);
    try color_map.put("origin/topic", scmHistory.history_item_remote_ref_color);
    try color_map.put("origin/main", scmHistory.history_item_base_ref_color);

    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        &color_map,
        null,
        null,
        null,
        false,
        false,
        null,
    );

    try testing.expectEqual(@as(usize, 6), view_models.len);

    // node a
    try testing.expectEqual(@as(usize, 0), view_models[0].input_swimlanes.len);

    try testing.expectEqual(@as(usize, 1), view_models[0].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[0].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[0].output_swimlanes[0].color);

    // node b
    try testing.expectEqual(@as(usize, 1), view_models[1].input_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[1].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[1].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[1].output_swimlanes.len);
    try testing.expectEqualStrings("c", view_models[1].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[1].output_swimlanes[0].color);

    // node c
    try testing.expectEqual(@as(usize, 1), view_models[2].input_swimlanes.len);
    try testing.expectEqualStrings("c", view_models[2].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[2].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[2].output_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[2].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[2].output_swimlanes[0].color);

    // node d
    try testing.expectEqual(@as(usize, 1), view_models[3].input_swimlanes.len);
    try testing.expectEqualStrings("d", view_models[3].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[3].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[3].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[3].output_swimlanes[0].color);

    // node e
    try testing.expectEqual(@as(usize, 1), view_models[4].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[4].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[4].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 2), view_models[4].output_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[4].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[4].output_swimlanes[0].color);
    try testing.expectEqualStrings("g", view_models[4].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_base_ref_color, view_models[4].output_swimlanes[1].color);

    // node g
    try testing.expectEqual(@as(usize, 2), view_models[5].input_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[5].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[5].input_swimlanes[0].color);
    try testing.expectEqualStrings("g", view_models[5].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_base_ref_color, view_models[5].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[5].output_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[5].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[5].output_swimlanes[0].color);
    try testing.expectEqualStrings("h", view_models[5].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_base_ref_color, view_models[5].output_swimlanes[1].color);
}

test "toISCMHistoryItemViewModelArray: graph with incoming/outgoing changes (remote ref first)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{"b"}, &.{.{ .id = "origin/main", .name = "origin/main" }}),
        try toSCMHistoryItem(&arena, "b", &.{"e"}, &.{}),
        try toSCMHistoryItem(&arena, "c", &.{"d"}, &.{.{ .id = "main", .name = "main" }}),
        try toSCMHistoryItem(&arena, "d", &.{"e"}, &.{}),
        try toSCMHistoryItem(&arena, "e", &.{"f"}, &.{}),
        try toSCMHistoryItem(&arena, "f", &.{"g"}, &.{}),
    };

    var color_map = scmHistory.ColorMap.init(allocator);
    try color_map.put("origin/main", scmHistory.history_item_remote_ref_color);
    try color_map.put("main", scmHistory.history_item_ref_color);

    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        &color_map,
        .{ .id = "main", .name = "main", .revision = "c" },
        .{ .id = "origin/main", .name = "origin/main", .revision = "a" },
        null,
        true,
        true,
        "e",
    );

    try testing.expectEqual(@as(usize, 8), view_models.len);

    // node a
    try testing.expectEqual(history.HistoryItemKind.node, view_models[0].kind);
    try testing.expectEqual(@as(usize, 0), view_models[0].input_swimlanes.len);

    try testing.expectEqual(@as(usize, 1), view_models[0].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[0].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[0].output_swimlanes[0].color);

    // node b
    try testing.expectEqual(history.HistoryItemKind.node, view_models[1].kind);
    try testing.expectEqual(@as(usize, 1), view_models[1].input_swimlanes.len);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[1].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[1].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[1].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[1].output_swimlanes[0].color);

    // outgoing changes node
    try testing.expectEqual(history.HistoryItemKind.outgoing_changes, view_models[2].kind);
    try testing.expectEqual(@as(usize, 1), view_models[2].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[2].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[2].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 2), view_models[2].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[2].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[2].output_swimlanes[0].color);
    try testing.expectEqualStrings("c", view_models[2].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[2].output_swimlanes[1].color);

    // node c
    try testing.expectEqual(history.HistoryItemKind.head, view_models[3].kind);
    try testing.expectEqual(@as(usize, 2), view_models[3].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[3].input_swimlanes[0].color);
    try testing.expectEqualStrings("c", view_models[3].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[3].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[3].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[3].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[3].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[3].output_swimlanes[1].color);

    // node d
    try testing.expectEqual(history.HistoryItemKind.node, view_models[4].kind);
    try testing.expectEqual(@as(usize, 2), view_models[4].input_swimlanes.len);
    try testing.expectEqualStrings(history.SCMIncomingHistoryItemId, view_models[4].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[4].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[4].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[4].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[4].output_swimlanes.len);
    try testing.expectEqualStrings(history.SCMIncomingHistoryItemId, view_models[4].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[4].output_swimlanes[0].color);
    try testing.expectEqualStrings("e", view_models[4].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[4].output_swimlanes[1].color);

    // incoming changes node
    try testing.expectEqual(history.HistoryItemKind.incoming_changes, view_models[5].kind);
    try testing.expectEqual(@as(usize, 2), view_models[5].input_swimlanes.len);
    try testing.expectEqualStrings(history.SCMIncomingHistoryItemId, view_models[5].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[5].input_swimlanes[0].color);
    try testing.expectEqualStrings("e", view_models[5].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[5].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[5].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[5].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[5].output_swimlanes[0].color);
    try testing.expectEqualStrings("e", view_models[5].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[5].output_swimlanes[1].color);

    // node e
    try testing.expectEqual(history.HistoryItemKind.node, view_models[6].kind);
    try testing.expectEqual(@as(usize, 2), view_models[6].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[6].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[6].input_swimlanes[0].color);
    try testing.expectEqualStrings("e", view_models[6].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[6].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 1), view_models[6].output_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[6].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[6].output_swimlanes[0].color);

    // node f
    try testing.expectEqual(history.HistoryItemKind.node, view_models[7].kind);
    try testing.expectEqual(@as(usize, 1), view_models[7].input_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[7].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[7].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[7].output_swimlanes.len);
    try testing.expectEqualStrings("g", view_models[7].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[7].output_swimlanes[0].color);
}

test "toISCMHistoryItemViewModelArray: graph with incoming/outgoing changes (local ref first)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{"b"}, &.{.{ .id = "main", .name = "main" }}),
        try toSCMHistoryItem(&arena, "b", &.{"e"}, &.{}),
        try toSCMHistoryItem(&arena, "c", &.{"d"}, &.{.{ .id = "origin/main", .name = "origin/main" }}),
        try toSCMHistoryItem(&arena, "d", &.{"e"}, &.{}),
        try toSCMHistoryItem(&arena, "e", &.{"f"}, &.{}),
        try toSCMHistoryItem(&arena, "f", &.{"g"}, &.{}),
    };

    var color_map = scmHistory.ColorMap.init(allocator);
    try color_map.put("origin/main", scmHistory.history_item_remote_ref_color);
    try color_map.put("main", scmHistory.history_item_ref_color);

    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        &color_map,
        .{ .id = "main", .name = "main", .revision = "a" },
        .{ .id = "origin/main", .name = "origin/main", .revision = "c" },
        null,
        true,
        true,
        "e",
    );

    try testing.expectEqual(@as(usize, 8), view_models.len);

    // outgoing changes node
    try testing.expectEqual(history.HistoryItemKind.outgoing_changes, view_models[0].kind);
    try testing.expectEqual(@as(usize, 0), view_models[0].input_swimlanes.len);

    try testing.expectEqual(@as(usize, 1), view_models[0].output_swimlanes.len);
    try testing.expectEqualStrings("a", view_models[0].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[0].output_swimlanes[0].color);

    // node a
    try testing.expectEqual(history.HistoryItemKind.head, view_models[1].kind);
    try testing.expectEqual(@as(usize, 1), view_models[1].input_swimlanes.len);
    try testing.expectEqualStrings("a", view_models[1].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[1].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[1].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[1].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[1].output_swimlanes[0].color);

    // node b
    try testing.expectEqual(history.HistoryItemKind.node, view_models[2].kind);
    try testing.expectEqual(@as(usize, 1), view_models[2].input_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[2].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[2].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[2].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[2].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[2].output_swimlanes[0].color);

    // node c
    try testing.expectEqual(history.HistoryItemKind.node, view_models[3].kind);
    try testing.expectEqual(@as(usize, 1), view_models[3].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[3].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 2), view_models[3].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[3].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[3].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[3].output_swimlanes[1].color);

    // node d
    try testing.expectEqual(history.HistoryItemKind.node, view_models[4].kind);
    try testing.expectEqual(@as(usize, 2), view_models[4].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[4].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[4].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[4].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[4].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[4].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[4].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[4].output_swimlanes[0].color);
    try testing.expectEqualStrings(history.SCMIncomingHistoryItemId, view_models[4].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[4].output_swimlanes[1].color);

    // incoming changes node
    try testing.expectEqual(history.HistoryItemKind.incoming_changes, view_models[5].kind);
    try testing.expectEqual(@as(usize, 2), view_models[5].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[5].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[5].input_swimlanes[0].color);
    try testing.expectEqualStrings(history.SCMIncomingHistoryItemId, view_models[5].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[5].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[5].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[5].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[5].output_swimlanes[0].color);
    try testing.expectEqualStrings("e", view_models[5].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[5].output_swimlanes[1].color);

    // node e
    try testing.expectEqual(history.HistoryItemKind.node, view_models[6].kind);
    try testing.expectEqual(@as(usize, 2), view_models[6].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[6].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[6].input_swimlanes[0].color);
    try testing.expectEqualStrings("e", view_models[6].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[6].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 1), view_models[6].output_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[6].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[6].output_swimlanes[0].color);

    // node f
    try testing.expectEqual(history.HistoryItemKind.node, view_models[7].kind);
    try testing.expectEqual(@as(usize, 1), view_models[7].input_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[7].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[7].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[7].output_swimlanes.len);
    try testing.expectEqualStrings("g", view_models[7].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[7].output_swimlanes[0].color);
}

test "toISCMHistoryItemViewModelArray: graph with merged incoming changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{"b"}, &.{.{ .id = "origin/main", .name = "origin/main" }}),
        try toSCMHistoryItem(&arena, "b", &.{ "c", "d" }, &.{}),
        try toSCMHistoryItem(&arena, "c", &.{"e"}, &.{.{ .id = "main", .name = "main" }}),
        try toSCMHistoryItem(&arena, "d", &.{"e"}, &.{}),
        try toSCMHistoryItem(&arena, "e", &.{"f"}, &.{}),
        try toSCMHistoryItem(&arena, "f", &.{"g"}, &.{}),
    };

    var color_map = scmHistory.ColorMap.init(allocator);
    try color_map.put("origin/main", scmHistory.history_item_remote_ref_color);
    try color_map.put("main", scmHistory.history_item_ref_color);

    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        &color_map,
        .{ .id = "main", .name = "main", .revision = "c" },
        .{ .id = "origin/main", .name = "origin/main", .revision = "a" },
        null,
        true,
        true,
        "c",
    );

    try testing.expectEqual(@as(usize, 6), view_models.len);

    // node a
    try testing.expectEqual(history.HistoryItemKind.node, view_models[0].kind);
    try testing.expectEqual(@as(usize, 0), view_models[0].input_swimlanes.len);

    try testing.expectEqual(@as(usize, 1), view_models[0].output_swimlanes.len);
    try testing.expectEqualStrings("b", view_models[0].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[0].output_swimlanes[0].color);

    // node b
    try testing.expectEqual(history.HistoryItemKind.node, view_models[1].kind);
    try testing.expectEqual(@as(usize, 1), view_models[1].input_swimlanes.len);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[1].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 2), view_models[1].output_swimlanes.len);
    try testing.expectEqualStrings("c", view_models[1].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[1].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[1].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[1].output_swimlanes[1].color);

    // node c
    try testing.expectEqual(history.HistoryItemKind.head, view_models[2].kind);
    try testing.expectEqual(@as(usize, 2), view_models[2].input_swimlanes.len);
    try testing.expectEqualStrings("c", view_models[2].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_remote_ref_color, view_models[2].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[2].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[2].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[2].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[2].output_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[2].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[2].output_swimlanes[1].color);

    // node d
    try testing.expectEqual(history.HistoryItemKind.node, view_models[3].kind);
    try testing.expectEqual(@as(usize, 2), view_models[3].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[3].input_swimlanes[0].color);
    try testing.expectEqualStrings("d", view_models[3].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 2), view_models[3].output_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[3].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[3].output_swimlanes[0].color);
    try testing.expectEqualStrings("e", view_models[3].output_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[3].output_swimlanes[1].color);

    // node e
    try testing.expectEqual(history.HistoryItemKind.node, view_models[4].kind);
    try testing.expectEqual(@as(usize, 2), view_models[4].input_swimlanes.len);
    try testing.expectEqualStrings("e", view_models[4].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[4].input_swimlanes[0].color);
    try testing.expectEqualStrings("e", view_models[4].input_swimlanes[1].id);
    try testing.expectEqualStrings(scmHistory.color_registry[0], view_models[4].input_swimlanes[1].color);

    try testing.expectEqual(@as(usize, 1), view_models[4].output_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[4].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[4].output_swimlanes[0].color);

    // node f
    try testing.expectEqual(history.HistoryItemKind.node, view_models[5].kind);
    try testing.expectEqual(@as(usize, 1), view_models[5].input_swimlanes.len);
    try testing.expectEqualStrings("f", view_models[5].input_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[5].input_swimlanes[0].color);

    try testing.expectEqual(@as(usize, 1), view_models[5].output_swimlanes.len);
    try testing.expectEqualStrings("g", view_models[5].output_swimlanes[0].id);
    try testing.expectEqualStrings(scmHistory.history_item_ref_color, view_models[5].output_swimlanes[0].color);
}

// ---------------------------------------------------------------------------
// Terminal golden cells (not in the upstream test file)
// ---------------------------------------------------------------------------

test "scmHistory golden cells: linear graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{"b"}, &.{}),
        try toSCMHistoryItem(&arena, "b", &.{"c"}, &.{}),
        try toSCMHistoryItem(&arena, "c", &.{}, &.{}),
    };
    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        null,
        null,
        null,
        null,
        false,
        false,
        null,
    );

    // Every linear row is lane 0: a blank gutter cell then the `●` node.
    for (view_models) |*view_model| {
        const cells = try scmHistory.renderSCMHistoryItemGraph(allocator, view_model);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, ' '), cells[0].cp);
        try testing.expectEqual(@as(u21, '\u{25CF}'), cells[1].cp);
        try testing.expectEqualStrings(scmHistory.color_registry[0], cells[1].color.?);
    }
}

test "scmHistory golden cells: merge graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{"b"}, &.{}),
        try toSCMHistoryItem(&arena, "b", &.{ "c", "d" }, &.{}),
    };
    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        null,
        null,
        null,
        null,
        false,
        false,
        null,
    );

    // Merge row `b(c,d)`: node `◎` in lane 0 and the `╲` shift to lane 1.
    const cells = try scmHistory.renderSCMHistoryItemGraph(allocator, &view_models[1]);
    try testing.expectEqual(@as(usize, 3), cells.len);
    try testing.expectEqual(@as(u21, ' '), cells[0].cp);
    try testing.expectEqual(@as(u21, '\u{25CE}'), cells[1].cp);
    try testing.expectEqualStrings(scmHistory.color_registry[0], cells[1].color.?);
    try testing.expectEqual(@as(u21, '\u{2572}'), cells[2].cp);
    try testing.expectEqualStrings(scmHistory.color_registry[1], cells[2].color.?);
}

test "scmHistory golden cells: HEAD circle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = [_]history.ISCMHistoryItem{
        try toSCMHistoryItem(&arena, "a", &.{"b"}, &.{}),
        try toSCMHistoryItem(&arena, "b", &.{}, &.{}),
    };
    const view_models = try scmHistory.toISCMHistoryItemViewModelArray(
        allocator,
        &models,
        null,
        .{ .id = "main", .name = "main", .revision = "b" },
        null,
        null,
        false,
        false,
        null,
    );
    try testing.expectEqual(history.HistoryItemKind.head, view_models[1].kind);

    // The checked-out commit renders as the `◉` HEAD circle.
    const cells = try scmHistory.renderSCMHistoryItemGraph(allocator, &view_models[1]);
    try testing.expectEqual(@as(usize, 2), cells.len);
    try testing.expectEqual(@as(u21, ' '), cells[0].cp);
    try testing.expectEqual(@as(u21, '\u{25C9}'), cells[1].cp);
    try testing.expectEqualStrings(scmHistory.color_registry[0], cells[1].color.?);
}

test "scmHistory golden cells: placeholder" {
    const allocator = std.testing.allocator;

    const columns = [_]history.ISCMHistoryItemGraphNode{
        .{ .id = "a", .color = scmHistory.color_registry[0] },
        .{ .id = "b", .color = scmHistory.color_registry[1] },
    };
    const cells = try scmHistory.renderSCMHistoryGraphPlaceholder(allocator, &columns, 1);
    defer allocator.free(cells);

    // Unhighlighted lanes are `│`, the highlighted lane is the heavy `┃`.
    try testing.expectEqual(@as(usize, 3), cells.len);
    try testing.expectEqual(@as(u21, ' '), cells[0].cp);
    try testing.expectEqual(@as(u21, '\u{2502}'), cells[1].cp);
    try testing.expectEqualStrings(scmHistory.color_registry[0], cells[1].color.?);
    try testing.expectEqual(@as(u21, '\u{2503}'), cells[2].cp);
    try testing.expectEqualStrings(scmHistory.color_registry[1], cells[2].color.?);
}
