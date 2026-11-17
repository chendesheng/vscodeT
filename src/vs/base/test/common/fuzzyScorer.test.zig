// Port of the `prepareQuery` case of `src/vs/base/test/common/fuzzyScorer.test.ts`.
const std = @import("std");
const fuzzy = @import("../../common/fuzzyScorer.zig");

test "prepareQuery" {
    const allocator = std.testing.allocator;

    const checks = [_]struct { query: []const u8, normalized: []const u8 }{
        .{ .query = " f*a ", .normalized = "fa" },
        .{ .query = " f…a ", .normalized = "fa" },
        .{ .query = "main#", .normalized = "main" },
        .{ .query = "foo*", .normalized = "foo" },
        .{ .query = "model Tester.ts", .normalized = "modelTester.ts" },
        .{ .query = "\"hello\"", .normalized = "hello" },
    };
    for (checks) |check| {
        const query = try fuzzy.prepareQuery(allocator, check.query);
        defer query.deinit(allocator);
        try std.testing.expectEqualStrings(check.normalized, query.normalized);
    }

    const main = try fuzzy.prepareQuery(allocator, "main#");
    defer main.deinit(allocator);
    try std.testing.expectEqualStrings("main#", main.original);

    const model = try fuzzy.prepareQuery(allocator, "model Tester.ts");
    defer model.deinit(allocator);
    try std.testing.expectEqualStrings("model Tester.ts", model.original);
    try std.testing.expectEqualStrings("model tester.ts", model.originalLowercase);
    try std.testing.expect(!model.expectContiguousMatch);
    try std.testing.expect(model.values != null);
    try std.testing.expectEqual(@as(usize, 2), model.values.?.len);

    const uppercase = try fuzzy.prepareQuery(allocator, "Model Tester.ts");
    defer uppercase.deinit(allocator);
    try std.testing.expectEqualStrings("modeltester.ts", uppercase.normalizedLowercase);

    const no_sep = try fuzzy.prepareQuery(allocator, "ModelTester.ts");
    defer no_sep.deinit(allocator);
    try std.testing.expect(!no_sep.containsPathSeparator);

    const sep_query = try fuzzy.prepareQuery(allocator, "Model/Tester.ts");
    defer sep_query.deinit(allocator);
    try std.testing.expect(sep_query.containsPathSeparator);

    const exact = try fuzzy.prepareQuery(allocator, "\"hello\"");
    defer exact.deinit(allocator);
    try std.testing.expect(exact.expectContiguousMatch);

    const spaced = try fuzzy.prepareQuery(allocator, "He*llo World");
    defer spaced.deinit(allocator);
    try std.testing.expectEqualStrings("He*llo World", spaced.original);
    try std.testing.expectEqualStrings("HelloWorld", spaced.normalized);
    try std.testing.expectEqualStrings("helloworld", spaced.normalizedLowercase);
    try std.testing.expectEqual(@as(usize, 2), spaced.values.?.len);
    try std.testing.expectEqualStrings("He*llo", spaced.values.?[0].original);
    try std.testing.expectEqualStrings("Hello", spaced.values.?[0].normalized);
    try std.testing.expectEqualStrings("hello", spaced.values.?[0].normalizedLowercase);
    try std.testing.expectEqualStrings("World", spaced.values.?[1].original);
    try std.testing.expectEqualStrings("World", spaced.values.?[1].normalized);

    const restored = try fuzzy.pieceToQuery(allocator, spaced.values.?);
    defer restored.deinit(allocator);
    try std.testing.expectEqualStrings(spaced.original, restored.original);
    try std.testing.expectEqual(spaced.values.?.len, restored.values.?.len);
    try std.testing.expectEqual(spaced.containsPathSeparator, restored.containsPathSeparator);

    const padded = try fuzzy.prepareQuery(allocator, " Hello   World  \t");
    defer padded.deinit(allocator);
    try std.testing.expectEqualStrings(" Hello   World  \t", padded.original);
    try std.testing.expectEqualStrings(" hello   world  \t", padded.originalLowercase);
    try std.testing.expectEqualStrings("HelloWorld", padded.normalized);
    try std.testing.expectEqualStrings("helloworld", padded.normalizedLowercase);
    try std.testing.expectEqual(@as(usize, 2), padded.values.?.len);
    try std.testing.expectEqualStrings("Hello", padded.values.?[0].original);
    try std.testing.expectEqualStrings("hello", padded.values.?[0].originalLowercase);
    try std.testing.expectEqualStrings("World", padded.values.?[1].original);

    const posix = try fuzzy.prepareQuery(allocator, "/some/path");
    defer posix.deinit(allocator);
    try std.testing.expectEqualStrings("/some/path", posix.pathNormalized);
    try std.testing.expectEqualStrings("/some/path", posix.normalized);
    try std.testing.expect(posix.containsPathSeparator);

    const backslash = try fuzzy.prepareQuery(allocator, "\\some\\path");
    defer backslash.deinit(allocator);
    try std.testing.expectEqualStrings("/some/path", backslash.pathNormalized);
    try std.testing.expectEqualStrings("/some/path", backslash.normalized);
    try std.testing.expect(backslash.containsPathSeparator);
}

fn doScore(allocator: std.mem.Allocator, target: []const u8, query: []const u8, allow_non_contiguous: bool) !fuzzy.FuzzyScore {
    const prepared = try fuzzy.prepareQuery(allocator, query);
    defer prepared.deinit(allocator);
    return fuzzy.scoreFuzzy(allocator, target, prepared.normalized, prepared.normalizedLowercase, allow_non_contiguous);
}

test "score (fuzzy)" {
    const allocator = std.testing.allocator;
    const target = "HelLo-World";
    const queries = [_][]const u8{ "HelLo-World", "hello-world", "HW", "hw", "H", "h", "W", "Ld", "ld", "w", "L", "l", "4" };
    var previous: i64 = std.math.maxInt(i64);
    for (queries) |query| {
        const score = try doScore(allocator, target, query, true);
        defer score.deinit(allocator);
        try std.testing.expect(score.score <= previous);
        previous = score.score;
    }
}

test "score (non fuzzy)" {
    const allocator = std.testing.allocator;
    const target = "HelLo-World";

    const identity = try doScore(allocator, target, "HelLo-World", false);
    defer identity.deinit(allocator);
    try std.testing.expect(identity.score > 0);
    try std.testing.expectEqual(target.len, identity.positions.len);

    const mixed = try doScore(allocator, target, "hello-world", false);
    defer mixed.deinit(allocator);
    try std.testing.expect(mixed.score > 0);

    const non_contiguous = try doScore(allocator, target, "HW", false);
    defer non_contiguous.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 0), non_contiguous.score);

    const prefix = try doScore(allocator, target, "h", false);
    defer prefix.deinit(allocator);
    try std.testing.expect(prefix.score > 0);

    const middle = try doScore(allocator, target, "ello", false);
    defer middle.deinit(allocator);
    try std.testing.expect(middle.score > 0);

    const suffix = try doScore(allocator, target, "ld", false);
    defer suffix.deinit(allocator);
    try std.testing.expect(suffix.score > 0);

    const gap = try doScore(allocator, target, "eo", false);
    defer gap.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 0), gap.score);
}

fn doScore2(allocator: std.mem.Allocator, target: []const u8, query_text: []const u8, offset: usize) !fuzzy.FuzzyScore2 {
    const prepared = try fuzzy.prepareQuery(allocator, query_text);
    defer prepared.deinit(allocator);
    return fuzzy.scoreFuzzy2(allocator, target, &prepared, 0, offset);
}

test "fuzzyScore2 (matching)" {
    const allocator = std.testing.allocator;
    const target = "HelLo-World";
    for ([_]usize{ 0, 3 }) |offset| {
        const actual_target = if (offset == 0) target else try std.fmt.allocPrint(allocator, "123{s}", .{target});
        defer if (offset != 0) allocator.free(actual_target);

        const full = try doScore2(allocator, actual_target, "HelLo-World", offset);
        defer full.deinit(allocator);
        try std.testing.expect(full.score != null);
        try std.testing.expectEqual(@as(usize, 1), full.matches.len);
        try std.testing.expectEqual(@as(usize, offset), full.matches[0].start);
        try std.testing.expectEqual(@as(usize, target.len + offset), full.matches[0].end);

        const separated = try doScore2(allocator, actual_target, "HW", offset);
        defer separated.deinit(allocator);
        try std.testing.expect(separated.score != null);
        try std.testing.expectEqual(@as(usize, 2), separated.matches.len);
        try std.testing.expectEqual(@as(usize, offset), separated.matches[0].start);
        try std.testing.expectEqual(@as(usize, 1 + offset), separated.matches[0].end);
        try std.testing.expectEqual(@as(usize, 6 + offset), separated.matches[1].start);
        try std.testing.expectEqual(@as(usize, 7 + offset), separated.matches[1].end);
    }
}

test "fuzzyScore2 (multiple queries)" {
    const allocator = std.testing.allocator;
    const target = "HelLo-World";

    const first = try doScore2(allocator, target, "HelLo", 0);
    defer first.deinit(allocator);
    const second = try doScore2(allocator, target, "World", 0);
    defer second.deinit(allocator);
    var single_matches = std.array_list.Managed(fuzzy.Match).init(allocator);
    defer single_matches.deinit();
    try single_matches.appendSlice(first.matches);
    try single_matches.appendSlice(second.matches);

    const Check = struct {
        fn score(alloc: std.mem.Allocator, target_value: []const u8, query: []const u8, singles: []const fuzzy.Match, minimum: i64) !void {
            const multi = try doScore2(alloc, target_value, query, 0);
            defer multi.deinit(alloc);
            try std.testing.expect(multi.score != null);
            try std.testing.expect(multi.score.? >= minimum);
            try std.testing.expectEqual(singles.len, multi.matches.len);
            for (singles, multi.matches) |expected, actual| {
                try std.testing.expectEqual(expected.start, actual.start);
                try std.testing.expectEqual(expected.end, actual.end);
            }
        }
        fn noScore(alloc: std.mem.Allocator, target_value: []const u8, query: []const u8) !void {
            const multi = try doScore2(alloc, target_value, query, 0);
            defer multi.deinit(alloc);
            try std.testing.expect(multi.score == null);
            try std.testing.expectEqual(@as(usize, 0), multi.matches.len);
        }
    };

    const minimum = first.score.? + second.score.?;
    try Check.score(allocator, target, "HelLo World", single_matches.items, minimum);
    try Check.score(allocator, target, "World HelLo", single_matches.items, minimum);
    try Check.score(allocator, target, "World HelLo World", single_matches.items, minimum);
    try Check.noScore(allocator, target, "World HelLo Nothing");
    try Check.noScore(allocator, target, "More Nothing");
}

test "fuzzyScore2 (#95716)" {
    const allocator = std.testing.allocator;
    const result = try doScore2(allocator, "# ❌ Wow", "❌", 0);
    defer result.deinit(allocator);
    try std.testing.expect(result.score != null);
    try std.testing.expect(result.matches.len > 0);
}

const TestItem = struct {
    label: []const u8,
    description: ?[]const u8,
    path_value: ?[]const u8,

    fn accessor() fuzzy.ItemAccessor {
        return .{
            .context = @ptrFromInt(@alignOf(usize)),
            .get_item_label = labelFn,
            .get_item_description = descriptionFn,
            .get_item_path = pathFn,
        };
    }
    fn labelFn(_: *anyopaque, item: *const anyopaque) ?[]const u8 {
        const value: *const TestItem = @ptrCast(@alignCast(item));
        return value.label;
    }
    fn descriptionFn(_: *anyopaque, item: *const anyopaque) ?[]const u8 {
        const value: *const TestItem = @ptrCast(@alignCast(item));
        return value.description;
    }
    fn pathFn(_: *anyopaque, item: *const anyopaque) ?[]const u8 {
        const value: *const TestItem = @ptrCast(@alignCast(item));
        return value.path_value;
    }
};

test "scoreItem - identity, prefix, camelcase and description matches" {
    const allocator = std.testing.allocator;
    const item = TestItem{
        .label = "someFile123.txt",
        .description = "/xyz/some/path",
        .path_value = "/xyz/some/path/someFile123.txt",
    };

    const Identity = struct {
        fn score(alloc: std.mem.Allocator, value: *const TestItem, query: []const u8) !fuzzy.ItemScore {
            const prepared = try fuzzy.prepareQuery(alloc, query);
            defer prepared.deinit(alloc);
            return fuzzy.scoreItemFuzzy(alloc, value, &prepared, true, TestItem.accessor());
        }
    };

    const identity = try Identity.score(allocator, &item, "/xyz/some/path/someFile123.txt");
    defer identity.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1 << 18), identity.score);
    try std.testing.expectEqual(@as(usize, 1), identity.label_match.?.len);
    try std.testing.expectEqual(@as(usize, 0), identity.label_match.?[0].start);
    try std.testing.expectEqual(@as(usize, 1), identity.description_match.?.len);

    const prefix = try Identity.score(allocator, &item, "som");
    defer prefix.deinit(allocator);
    try std.testing.expect(prefix.score > 0);
    try std.testing.expect(prefix.description_match == null);
    try std.testing.expectEqual(@as(usize, 1), prefix.label_match.?.len);
    try std.testing.expectEqual(@as(usize, 0), prefix.label_match.?[0].start);
    try std.testing.expectEqual(@as(usize, 3), prefix.label_match.?[0].end);

    const camel = try Identity.score(allocator, &item, "sF");
    defer camel.deinit(allocator);
    try std.testing.expect(camel.score > 0);
    try std.testing.expect(camel.description_match == null);
    try std.testing.expectEqual(@as(usize, 2), camel.label_match.?.len);
    try std.testing.expectEqual(@as(usize, 0), camel.label_match.?[0].start);
    try std.testing.expectEqual(@as(usize, 1), camel.label_match.?[0].end);
    try std.testing.expectEqual(@as(usize, 4), camel.label_match.?[1].start);
    try std.testing.expectEqual(@as(usize, 5), camel.label_match.?[1].end);

    const description = try Identity.score(allocator, &item, "xyz");
    defer description.deinit(allocator);
    try std.testing.expect(description.score > 0);
    try std.testing.expect(description.description_match != null);

    const quoted = try Identity.score(allocator, &item, "\"someFile123.txt\"");
    defer quoted.deinit(allocator);
    try std.testing.expect(quoted.score > 0);
}

test "compareItemsByScore - identity" {
    const allocator = std.testing.allocator;
    var a = TestItem{ .label = "fileA.txt", .description = "/some", .path_value = "/some/fileA.txt" };
    var b = TestItem{ .label = "fileB.txt", .description = "/some", .path_value = "/some/fileB.txt" };
    const prepared = try fuzzy.prepareQuery(allocator, "/some/fileA.txt");
    defer prepared.deinit(allocator);

    const forward = try fuzzy.compareItemsByFuzzyScore(allocator, &a, &b, &prepared, true, TestItem.accessor());
    try std.testing.expectEqual(@as(i32, -1), forward);
    const backward = try fuzzy.compareItemsByFuzzyScore(allocator, &b, &a, &prepared, true, TestItem.accessor());
    try std.testing.expectEqual(@as(i32, 1), backward);
    const equal = try fuzzy.compareItemsByFuzzyScore(allocator, &a, &a, &prepared, true, TestItem.accessor());
    try std.testing.expectEqual(@as(i32, 0), equal);
}

const FixtureA = TestItem{ .label = "fileA.txt", .description = "/some/path", .path_value = "/some/path/fileA.txt" };
const FixtureB = TestItem{ .label = "fileB.txt", .description = "/some/path/other", .path_value = "/some/path/other/fileB.txt" };
const FixtureC = TestItem{ .label = "fileC.txt", .description = "/unrelated/some/path/other", .path_value = "/unrelated/some/path/other/fileC.txt" };

fn sortItems(allocator: std.mem.Allocator, items: []*TestItem, query_text: []const u8) !void {
    const prepared = try fuzzy.prepareQuery(allocator, query_text);
    defer prepared.deinit(allocator);
    var index: usize = 1;
    while (index < items.len) : (index += 1) {
        const current = items[index];
        var position = index;
        while (position > 0) : (position -= 1) {
            const comparison = try fuzzy.compareItemsByFuzzyScore(allocator, current, items[position - 1], &prepared, true, TestItem.accessor());
            if (comparison >= 0) break;
            items[position] = items[position - 1];
        }
        items[position] = current;
    }
}

fn expectOrder(allocator: std.mem.Allocator, items: []const *TestItem, query: []const u8, expected: []const *TestItem) !void {
    const copy = try allocator.alloc(*TestItem, items.len);
    defer allocator.free(copy);
    const copy_reversed = try allocator.alloc(*TestItem, items.len);
    defer allocator.free(copy_reversed);
    for (items, 0..) |item, index| {
        copy[index] = item;
        copy_reversed[items.len - 1 - index] = item;
    }
    try sortItems(allocator, copy, query);
    try sortItems(allocator, copy_reversed, query);
    for (expected, 0..) |item, index| {
        try std.testing.expectEqual(item, copy[index]);
        try std.testing.expectEqual(item, copy_reversed[index]);
    }
}

test "compareFilesByScore - identity and basename prefix" {
    const allocator = std.testing.allocator;
    var a = FixtureA;
    var b = FixtureB;
    var c = FixtureC;
    const items = [_]*TestItem{ &a, &b, &c };

    try expectOrder(allocator, @constCast(&items), a.path_value.?, &[_]*TestItem{ &a, &b, &c });
    try expectOrder(allocator, @constCast(&items), b.path_value.?, &[_]*TestItem{ &b, &a, &c });
    try expectOrder(allocator, @constCast(&items), a.label, &[_]*TestItem{ &a, &b, &c });
    try expectOrder(allocator, @constCast(&items), b.label, &[_]*TestItem{ &b, &a, &c });
}

test "compareFilesByScore - basename camelcase" {
    const allocator = std.testing.allocator;
    var a = FixtureA;
    var b = FixtureB;
    var c = FixtureC;
    const items = [_]*TestItem{ &a, &b, &c };
    try expectOrder(allocator, @constCast(&items), "fA", &[_]*TestItem{ &a, &b, &c });
    try expectOrder(allocator, @constCast(&items), "fB", &[_]*TestItem{ &b, &a, &c });
}

test "compareFilesByScore - basename and path scores" {
    const allocator = std.testing.allocator;
    var a = FixtureA;
    var b = FixtureB;
    var c = FixtureC;
    const items = [_]*TestItem{ &a, &b, &c };

    try expectOrder(allocator, @constCast(&items), "fileA", &[_]*TestItem{ &a, &b, &c });
    try expectOrder(allocator, @constCast(&items), "fileB", &[_]*TestItem{ &b, &a, &c });
    try expectOrder(allocator, @constCast(&items), "pathfileA", &[_]*TestItem{ &a, &b, &c });
    try expectOrder(allocator, @constCast(&items), "pathfileB", &[_]*TestItem{ &b, &a, &c });
}

test "compareFilesByScore - preferred shorter basenames" {
    const allocator = std.testing.allocator;
    var a = FixtureA;
    var b = TestItem{ .label = "fileBLonger.txt", .description = "/some/path/other", .path_value = "/some/path/other/fileBLonger.txt" };
    var c = FixtureC;
    const items = [_]*TestItem{ &a, &b, &c };
    try expectOrder(allocator, @constCast(&items), "somepath", &[_]*TestItem{ &a, &b, &c });
}

test "compareFilesByScore - shorter basenames, paths and label preference" {
    const allocator = std.testing.allocator;
    {
        var a = FixtureA;
        var b = TestItem{ .label = "fileBLonger.txt", .description = "/some/path/other", .path_value = "/some/path/other/fileBLonger.txt" };
        var c = TestItem{ .label = "fileC.txt", .description = "/unrelated/the/path/other", .path_value = "/unrelated/the/path/other/fileC.txt" };
        const items = [_]*TestItem{ &a, &b, &c };
        try expectOrder(allocator, &items, "file", &[_]*TestItem{ &a, &c, &b });
        try expectOrder(allocator, &items, "somepath", &[_]*TestItem{ &a, &b, &c });
    }
    {
        var a = TestItem{ .label = "t1.js", .description = "config/test", .path_value = "config/test/t1.js" };
        var b = TestItem{ .label = "test.js", .description = "config", .path_value = "config/test.js" };
        var c = TestItem{ .label = "t2.js", .description = "config/test", .path_value = "config/test/t2.js" };
        const items = [_]*TestItem{ &a, &b, &c };
        try expectOrder(allocator, &items, "co/te", &[_]*TestItem{ &b, &a, &c });
    }
    {
        var a = TestItem{ .label = "arrow-left-dark.svg", .description = "parts/quick", .path_value = "parts/quick/arrow-left-dark.svg" };
        var b = TestItem{ .label = "quickopen.ts", .description = "parts/quickopen", .path_value = "parts/quickopen/quickopen.ts" };
        const items = [_]*TestItem{ &a, &b };
        try expectOrder(allocator, &items, "partsquick", &[_]*TestItem{ &b, &a });
    }
}

test "compareFilesByScore - camel case and compact matches" {
    const allocator = std.testing.allocator;
    {
        var a = TestItem{ .label = "NullPointerException.java", .description = "config/test", .path_value = "config/test/NullPointerException.java" };
        var b = TestItem{ .label = "nopointerexception.java", .description = "config/test", .path_value = "config/test/nopointerexception.java" };
        const items = [_]*TestItem{ &a, &b };
        try expectOrder(allocator, &items, "npe", &[_]*TestItem{ &a, &b });
        try expectOrder(allocator, &items, "NPE", &[_]*TestItem{ &a, &b });
    }
    {
        var a = TestItem{ .label = "openthisAnythingHandler.js", .description = "config/test", .path_value = "config/test/openthisAnythingHandler.js" };
        var b = TestItem{ .label = "openthisisnotsorelevantforthequeryAnyHand.js", .description = "config/test", .path_value = "config/test/openthisisnotsorelevantforthequeryAnyHand.js" };
        const items = [_]*TestItem{ &a, &b };
        try expectOrder(allocator, &items, "AH", &[_]*TestItem{ &b, &a });
    }
    {
        var a = TestItem{ .label = "examasdaple.js", .description = "config/test", .path_value = "config/test/examasdaple.js" };
        var b = TestItem{ .label = "exampleasdaasd.ts", .description = "config/test", .path_value = "config/test/exampleasdaasd.ts" };
        const items = [_]*TestItem{ &a, &b };
        try expectOrder(allocator, &items, "xp", &[_]*TestItem{ &b, &a });
    }
}

test "compareFilesByScore - compact matches on path" {
    const allocator = std.testing.allocator;
    {
        var a = TestItem{ .label = "file.js", .description = "config/test/examasdaple", .path_value = "config/test/examasdaple/file.js" };
        var b = TestItem{ .label = "file.ts", .description = "config/test/exampleasdaasd", .path_value = "config/test/exampleasdaasd/file.ts" };
        const items = [_]*TestItem{ &a, &b };
        try expectOrder(allocator, &items, "xp", &[_]*TestItem{ &b, &a });
    }
    {
        var a = TestItem{ .label = "thisfile.ts", .description = "config/example", .path_value = "config/example/thisfile.ts" };
        var b = TestItem{ .label = "file.js", .description = "config/24234243244/example", .path_value = "config/24234243244/example/file.js" };
        const items = [_]*TestItem{ &a, &b };
        try expectOrder(allocator, &items, "exfile", &[_]*TestItem{ &b, &a });
    }
}

test "compareFilesByScore - avoid match scattering (path segments)" {
    const allocator = std.testing.allocator;
    {
        var a = TestItem{ .label = "index.js", .description = "node_modules1/bundle/lib/model/modules/ot1", .path_value = "node_modules1/bundle/lib/model/modules/ot1/index.js" };
        var b = TestItem{ .label = "index.js", .description = "node_modules1/bundle/lib/model/modules/un1", .path_value = "node_modules1/bundle/lib/model/modules/un1/index.js" };
        var c = TestItem{ .label = "index.js", .description = "node_modules1/bundle/lib/model/modules/modu1", .path_value = "node_modules1/bundle/lib/model/modules/modu1/index.js" };
        var d = TestItem{ .label = "index.js", .description = "node_modules1/bundle/lib/model/modules/oddl1", .path_value = "node_modules1/bundle/lib/model/modules/oddl1/index.js" };
        const items = [_]*TestItem{ &a, &b, &c, &d };
        var copy = items;
        try sortItems(allocator, &copy, "modu1/index.js");
        try std.testing.expectEqual(&c, copy[0]);
        copy = items;
        try sortItems(allocator, &copy, "un1/index.js");
        try std.testing.expectEqual(&b, copy[0]);
    }
    {
        var a = TestItem{ .label = "constants.js", .description = "ui/src/utils", .path_value = "ui/src/utils/constants.js" };
        var b = TestItem{ .label = "index.js", .description = "ui/src/ui/Icons", .path_value = "ui/src/ui/Icons/index.js" };
        const items = [_]*TestItem{ &a, &b };
        try expectOrder(allocator, &items, "ui/icons", &[_]*TestItem{ &b, &a });
    }
}
