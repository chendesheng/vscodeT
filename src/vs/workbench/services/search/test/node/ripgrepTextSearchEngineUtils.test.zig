// Port of the argument/parser cases in
// `src/vs/workbench/services/search/test/node/ripgrepTextSearchEngineUtils.test.ts`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const search = @import("../../common/search.zig");
const engine = @import("../../node/ripgrepTextSearchEngine.zig");

fn hasArg(args: []const []const u8, wanted: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, wanted)) return true;
    return false;
}

fn globIndex(args: []const []const u8, wanted: []const u8) ?usize {
    var index: usize = 0;
    while (index + 1 < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "-g") and std.mem.eql(u8, args[index + 1], wanted)) return index;
    }
    return null;
}

fn replaceOwned(allocator: Allocator, field: *[]u8, value: []const u8) !void {
    const copy = try allocator.dupe(u8, value);
    allocator.free(field.*);
    field.* = copy;
}

fn makeQuery(allocator: Allocator, options: search.TextQueryOptions) !search.TextQuery {
    return search.TextQuery.initWithOptions(allocator, "foo", &.{"/repo"}, "", "", &.{}, options);
}

test "text rg args: base flags and context" {
    const allocator = std.testing.allocator;
    var query = try makeQuery(allocator, .{});
    defer query.deinit();
    var args = try engine.buildArgs(allocator, &query, .{ .folder = "/repo" }, .{});
    defer args.deinit();

    try std.testing.expect(hasArg(args.args, "--hidden"));
    try std.testing.expect(hasArg(args.args, "--no-require-git"));
    try std.testing.expect(hasArg(args.args, "--ignore-case"));
    try std.testing.expect(hasArg(args.args, "--json"));
    try std.testing.expect(hasArg(args.args, "--crlf"));
    try std.testing.expect(hasArg(args.args, "--fixed-strings"));
    try std.testing.expect(hasArg(args.args, "--no-config"));
    try std.testing.expect(!hasArg(args.args, "--before-context"));

    query.surrounding_context = 2;
    var context_args = try engine.buildArgs(allocator, &query, .{ .folder = "/repo" }, .{});
    defer context_args.deinit();
    try std.testing.expect(hasArg(context_args.args, "--before-context"));
    try std.testing.expect(hasArg(context_args.args, "--after-context"));
}

test "text rg args: includes, excludes and exceptions" {
    const allocator = std.testing.allocator;
    var query = try makeQuery(allocator, .{});
    try replaceOwned(allocator, &query.include_pattern, "**/*.ts");
    defer query.deinit();
    const excludes = [_][]const u8{"**/vendor"};
    var args = try engine.buildArgs(allocator, &query, .{ .folder = "/repo" }, .{
        .exclude_globs = &excludes,
    });
    defer args.deinit();
    try std.testing.expect(globIndex(args.args, "**/*.ts") != null);
    try std.testing.expect(globIndex(args.args, "!**/vendor") != null);
    try std.testing.expect(globIndex(args.args, "!*") == null);

    const exception_args_value = [_][]const u8{"node_modules/@types"};
    var exception_args = try engine.buildArgs(allocator, &query, .{ .folder = "/repo" }, .{
        .exclude_globs = &excludes,
        .exclude_exceptions = &exception_args_value,
    });
    defer exception_args.deinit();
    try std.testing.expect(hasArg(exception_args.args, "--no-ignore"));
    try std.testing.expect(globIndex(exception_args.args, "!**/vendor") == null);
    try std.testing.expect(globIndex(exception_args.args, "!*") != null);
}

test "text rg args: word and regex patterns" {
    const allocator = std.testing.allocator;
    var query = try makeQuery(allocator, .{});
    query.is_word_match = true;
    defer query.deinit();
    var args = try engine.buildArgs(allocator, &query, .{ .folder = "/repo" }, .{});
    defer args.deinit();
    try std.testing.expect(hasArg(args.args, "--regexp"));
    try std.testing.expect(hasArg(args.args, "--engine"));
    try std.testing.expect(!hasArg(args.args, "--fixed-strings"));

    query.is_word_match = false;
    query.is_regex = true;
    try replaceOwned(allocator, &query.pattern, "Game.?fL\\w?fe");
    var regex_args = try engine.buildArgs(allocator, &query, .{ .folder = "/repo" }, .{});
    defer regex_args.deinit();
    try std.testing.expect(hasArg(regex_args.args, "--engine"));
}

test "unicodeEscapesToPCRE2 and fixNewline" {
    const allocator = std.testing.allocator;
    const converted = try engine.unicodeEscapesToPCRE2(allocator, "G\\u{0061}m\\u0065");
    defer allocator.free(converted);
    try std.testing.expectEqualStrings("G\\x{0061}m\\x{0065}", converted);

    const fixed = try engine.fixNewline(allocator, "a\nb");
    defer allocator.free(fixed);
    try std.testing.expectEqualStrings("a\\r?\\nb", fixed);
}

const SinkState = struct {
    allocator: Allocator,
    files: std.array_list.Managed(engine.ParsedFile),

    fn onFile(context: *anyopaque, file: engine.ParsedFile) anyerror!void {
        const self: *SinkState = @ptrCast(@alignCast(context));
        try self.files.append(file);
    }
};

fn parseAll(allocator: Allocator, data: []const u8, max_results: usize) ![]engine.ParsedFile {
    var state = SinkState{ .allocator = allocator, .files = std.array_list.Managed(engine.ParsedFile).init(allocator) };
    var parser = engine.Parser.init(allocator, "/repo", .{}, max_results, .{
        .context = &state,
        .on_file = SinkState.onFile,
    });
    defer parser.deinit();
    try parser.handleData(data);
    try parser.flush();
    return state.files.toOwnedSlice();
}

fn freeParsedFiles(allocator: Allocator, files: []engine.ParsedFile) void {
    for (files) |*file| file.deinit();
    allocator.free(files);
}

const match_json =
    \\{"type":"match","data":{"path":{"text":"a.txt"},"lines":{"text":"foo bar\n"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"foo"},"start":0,"end":3},{"match":{"text":"bar"},"start":4,"end":7}]}}
    \\
;

test "Parser: match chunks and ranges" {
    const allocator = std.testing.allocator;
    const files = try parseAll(allocator, match_json, 100);
    defer freeParsedFiles(allocator, files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("a.txt", files[0].path);
    try std.testing.expectEqual(@as(usize, 1), files[0].matches.len);
    try std.testing.expectEqual(@as(usize, 2), files[0].matches[0].range_locations.len);
    try std.testing.expectEqualStrings("foo bar", files[0].matches[0].preview_text);
    try std.testing.expectEqual(@as(usize, 0), files[0].matches[0].range_locations[0].source.start_column);
    try std.testing.expectEqual(@as(usize, 3), files[0].matches[0].range_locations[0].source.end_column);
}

test "Parser: chunk boundaries and flush" {
    const allocator = std.testing.allocator;
    const split = @divTrunc(match_json.len, 2);
    var state = SinkState{ .allocator = allocator, .files = std.array_list.Managed(engine.ParsedFile).init(allocator) };
    var parser = engine.Parser.init(allocator, "/repo", .{}, 100, .{
        .context = &state,
        .on_file = SinkState.onFile,
    });
    defer parser.deinit();
    try parser.handleData(match_json[0..split]);
    try parser.handleData(match_json[split..]);
    try parser.flush();
    const files = try state.files.toOwnedSlice();
    defer freeParsedFiles(allocator, files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqual(@as(usize, 1), files[0].matches.len);
}

test "Parser: context rows" {
    const allocator = std.testing.allocator;
    const data =
        \\{"type":"context","data":{"path":{"text":"a.txt"},"lines":{"text":"before\nafter\n"},"line_number":4,"absolute_offset":0,"submatches":[]}}
        \\
    ;
    const files = try parseAll(allocator, data, 100);
    defer freeParsedFiles(allocator, files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqual(@as(usize, 2), files[0].contexts.len);
    try std.testing.expectEqual(@as(usize, 4), files[0].contexts[0].line_number);
    try std.testing.expectEqualStrings("before", files[0].contexts[0].text);
    try std.testing.expectEqual(@as(usize, 5), files[0].contexts[1].line_number);
    try std.testing.expectEqualStrings("after", files[0].contexts[1].text);
}

test "Parser: empty submatches and limit" {
    const allocator = std.testing.allocator;
    const data =
        \\{"type":"match","data":{"path":{"text":"a.txt"},"lines":{"text":"x\n"},"line_number":1,"absolute_offset":0,"submatches":[]}}
        \\
    ;
    const files = try parseAll(allocator, data, 1);
    defer freeParsedFiles(allocator, files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqual(@as(usize, 1), files[0].matches[0].range_locations.len);
}
