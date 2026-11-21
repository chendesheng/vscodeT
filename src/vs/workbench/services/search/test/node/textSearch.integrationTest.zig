// Port of the local ripgrep text-search cases in
// `src/vs/workbench/services/search/test/node/textSearch.integrationTest.ts`
// that the terminal Search view supports.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const search = @import("../../common/search.zig");
const workspace_context = @import("../../../workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const service_mod = @import("../../common/searchService.zig");
const SearchService = service_mod.SearchService;

const ContextCopy = struct {
    line_number: usize,
    text: []u8,
};

const FileCopy = struct {
    allocator: Allocator,
    path: []u8,
    match_count: usize,
    first_ranges: usize = 0,
    first_source: ?search.SearchRange = null,
    contexts: []ContextCopy,

    fn deinit(self: *FileCopy) void {
        self.allocator.free(self.path);
        for (self.contexts) |context| self.allocator.free(context.text);
        self.allocator.free(self.contexts);
    }
};

const QueryResult = struct {
    allocator: Allocator,
    files: []FileCopy,
    match_count: usize,
    limit_hit: bool,
    messages: []search.SearchMessage,

    fn deinit(self: *QueryResult) void {
        for (self.files) |*file| file.deinit();
        self.allocator.free(self.files);
        for (self.messages) |message| self.allocator.free(message.text);
        self.allocator.free(self.messages);
    }
};

fn rgAvailable(allocator: Allocator) bool {
    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "rg", "--version" },
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn rgSupportsPcre2(allocator: Allocator) bool {
    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "rg", "--pcre2-version" },
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn writeFile(tmp: *std.testing.TmpDir, io: Io, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| try tmp.dir.createDirPath(io, directory);
    var file = try tmp.dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

fn runQuery(
    allocator: Allocator,
    service: *SearchService,
    query: *const search.TextQuery,
) !QueryResult {
    var job = try service.startTextSearch(query);
    defer job.deinit(job.context);

    var files = std.array_list.Managed(FileCopy).init(allocator);
    errdefer {
        for (files.items) |*file| file.deinit();
        files.deinit();
    }
    var messages = std.array_list.Managed(search.SearchMessage).init(allocator);
    errdefer {
        for (messages.items) |message| allocator.free(message.text);
        messages.deinit();
    }
    var total: usize = 0;
    var limit_hit = false;
    while (true) {
        const step = try job.step(job.context, allocator, 64);
        defer allocator.free(step.results);
        for (step.messages) |message| {
            try messages.append(.{ .text = message.text, .kind = message.kind });
        }
        if (step.messages.len > 0) allocator.free(step.messages);
        limit_hit = step.limit_hit;
        for (step.results) |*file| {
            defer file.deinit();
            var contexts = std.array_list.Managed(ContextCopy).init(allocator);
            errdefer {
                for (contexts.items) |context| allocator.free(context.text);
                contexts.deinit();
            }
            for (file.contexts) |context| {
                try contexts.append(.{
                    .line_number = context.line_number,
                    .text = try allocator.dupe(u8, context.text),
                });
            }
            var match_count: usize = 0;
            for (file.results) |match| match_count += match.range_locations.len;
            const first_ranges = if (file.results.len > 0) file.results[0].range_locations.len else 0;
            const first_source = if (file.results.len > 0 and file.results[0].range_locations.len > 0)
                file.results[0].range_locations[0].source
            else
                null;
            total += match_count;
            try files.append(.{
                .allocator = allocator,
                .path = try allocator.dupe(u8, file.resource),
                .match_count = match_count,
                .first_ranges = first_ranges,
                .first_source = first_source,
                .contexts = try contexts.toOwnedSlice(),
            });
            contexts.deinit();
        }
        if (step.done) break;
    }
    return .{
        .allocator = allocator,
        .files = try files.toOwnedSlice(),
        .match_count = total,
        .limit_hit = limit_hit,
        .messages = try messages.toOwnedSlice(),
    };
}

fn makeQuery(
    allocator: Allocator,
    pattern: []const u8,
    roots: []const []const u8,
    options: search.TextQueryOptions,
) !search.TextQuery {
    return search.TextQuery.initWithOptions(allocator, pattern, roots, "", "", &.{}, options);
}

test "TextSearch: plain, regex and word searches" {
    if (!rgAvailable(std.testing.allocator)) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(&tmp, io, "a.txt", "alpha beta\nALPHA\n");
    try writeFile(&tmp, io, "sub/b.txt", "alpha\n");
    try writeFile(&tmp, io, "sub/c.md", "alpha\n");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    var service = SearchService.init(allocator, io, context, .{ .context = undefined, .read = null });

    var q = try makeQuery(allocator, "alpha", &.{root}, .{});
    defer q.deinit();
    var result = try runQuery(allocator, &service, &q);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.files.len);
    try std.testing.expectEqual(@as(usize, 4), result.match_count);

    q.is_regex = true;
    q.pattern[0] = 'a';
    var regex_result = try runQuery(allocator, &service, &q);
    defer regex_result.deinit();
    try std.testing.expect(regex_result.match_count >= 3);

    q.is_regex = false;
    q.is_word_match = true;
    var word_result = try runQuery(allocator, &service, &q);
    defer word_result.deinit();
    try std.testing.expectEqual(@as(usize, 4), word_result.match_count);
}

test "TextSearch: includes, excludes and ignore files" {
    if (!rgAvailable(std.testing.allocator)) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(&tmp, io, ".gitignore", "ignored.txt\n");
    try writeFile(&tmp, io, "kept.txt", "needle\n");
    try writeFile(&tmp, io, "ignored.txt", "needle\n");
    try writeFile(&tmp, io, "sub/kept.txt", "needle\n");
    try writeFile(&tmp, io, "sub/drop.md", "needle\n");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    var service = SearchService.init(allocator, io, context, .{ .context = undefined, .read = null });

    var q = try makeQuery(allocator, "needle", &.{root}, .{});
    defer q.deinit();
    var ignored = try runQuery(allocator, &service, &q);
    defer ignored.deinit();
    try std.testing.expectEqual(@as(usize, 3), ignored.files.len);

    try replaceOwned(allocator, &q.include_pattern, "**/sub/**");
    var included = try runQuery(allocator, &service, &q);
    defer included.deinit();
    try std.testing.expectEqual(@as(usize, 2), included.files.len);

    try replaceOwned(allocator, &q.include_pattern, "");
    try replaceOwned(allocator, &q.exclude_pattern, "**/sub/**");
    var excluded = try runQuery(allocator, &service, &q);
    defer excluded.deinit();
    try std.testing.expectEqual(@as(usize, 1), excluded.files.len);

    q.use_ignore_files = false;
    q.settings.use_ignore_files = false;
    try replaceOwned(allocator, &q.exclude_pattern, "");
    var unignored = try runQuery(allocator, &service, &q);
    defer unignored.deinit();
    try std.testing.expectEqual(@as(usize, 4), unignored.files.len);
}

test "TextSearch: surrounding contexts" {
    if (!rgAvailable(std.testing.allocator)) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(&tmp, io, "ctx.txt", "before\nneedle here\nafter\n");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    var service = SearchService.init(allocator, io, context, .{ .context = undefined, .read = null });

    var q = try makeQuery(allocator, "needle", &.{root}, .{ .surrounding_context = 1 });
    defer q.deinit();
    var result = try runQuery(allocator, &service, &q);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expectEqual(@as(usize, 2), result.files[0].contexts.len);
    try std.testing.expectEqual(@as(usize, 1), result.files[0].contexts[0].line_number);
    try std.testing.expectEqualStrings("before", result.files[0].contexts[0].text);
    try std.testing.expectEqual(@as(usize, 3), result.files[0].contexts[1].line_number);
    try std.testing.expectEqualStrings("after", result.files[0].contexts[1].text);
}

test "TextSearch: result limit and missing rg" {
    if (!rgAvailable(std.testing.allocator)) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(&tmp, io, "a.txt", "alpha alpha\nalpha\n");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    var service = SearchService.init(allocator, io, context, .{ .context = undefined, .read = null });

    var q = try makeQuery(allocator, "alpha", &.{root}, .{});
    defer q.deinit();
    q.max_results = 1;
    var limited = try runQuery(allocator, &service, &q);
    defer limited.deinit();
    try std.testing.expectEqual(@as(usize, 1), limited.match_count);
    try std.testing.expect(limited.limit_hit);

    var missing = SearchService.initWithOptions(allocator, io, context, .{ .context = undefined, .read = null }, .{
        .rg_path = "/nonexistent/ripgrep-for-text-search-tests",
    });
    var missing_query = try makeQuery(allocator, "alpha", &.{root}, .{});
    defer missing_query.deinit();
    var missing_result = try runQuery(allocator, &missing, &missing_query);
    defer missing_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing_result.match_count);
    try std.testing.expect(missing_result.messages.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, missing_result.messages[0].text, "ripgrep") != null);
}

test "TextSearch: open dirty buffers win over disk" {
    if (!rgAvailable(std.testing.allocator)) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(&tmp, io, "open.txt", "disk-only\n");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const path = try std.fs.path.join(allocator, &.{ root, "open.txt" });
    defer allocator.free(path);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();

    const State = struct {
        path: []const u8,
        fn read(ctx: *anyopaque, alloc: Allocator, requested: []const u8) anyerror!?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!std.mem.eql(u8, self.path, requested)) return null;
            return try alloc.dupe(u8, "buffer-alpha\n");
        }
        fn open(ctx: *anyopaque, alloc: Allocator) anyerror![][]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const paths = try alloc.alloc([]u8, 1);
            paths[0] = try alloc.dupe(u8, self.path);
            return paths;
        }
        fn free(_: *anyopaque, alloc: Allocator, paths: [][]u8) void {
            for (paths) |value| alloc.free(value);
            alloc.free(paths);
        }
    };
    var state = State{ .path = path };
    var service = SearchService.init(allocator, io, context, .{
        .context = &state,
        .read = State.read,
        .open_files = State.open,
        .free_paths = State.free,
    });

    var q = try makeQuery(allocator, "alpha", &.{root}, .{});
    defer q.deinit();
    var buffer_result = try runQuery(allocator, &service, &q);
    defer buffer_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), buffer_result.match_count);

    var disk_query = try makeQuery(allocator, "disk-only", &.{root}, .{});
    defer disk_query.deinit();
    var disk_result = try runQuery(allocator, &service, &disk_query);
    defer disk_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), disk_result.match_count);
}

fn replaceOwned(allocator: Allocator, field: *[]u8, value: []const u8) !void {
    const copy = try allocator.dupe(u8, value);
    allocator.free(field.*);
    field.* = copy;
}

test "TextSearch: exclude exceptions and sibling clauses" {
    if (!rgAvailable(std.testing.allocator)) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(&tmp, io, ".gitignore", "build/\n");
    try writeFile(&tmp, io, "build/keep.txt", "needle\n");
    try writeFile(&tmp, io, "build/drop.txt", "needle\n");
    try writeFile(&tmp, io, "node_modules/@types/index.d.ts", "needle\n");
    try writeFile(&tmp, io, "node_modules/other.txt", "needle\n");
    try writeFile(&tmp, io, "a.txt", "needle\n");
    try writeFile(&tmp, io, "site.css", "needle\n");
    try writeFile(&tmp, io, "site.less", "needle\n");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    var service = SearchService.init(allocator, io, context, .{ .context = undefined, .read = null });

    const entries = [_]@import("../../../../../base/common/glob.zig").ExcludeEntry{
        .{ .pattern = "node_modules" },
        .{ .pattern = "!node_modules/@types" },
        .{ .pattern = "!build/keep.txt" },
        .{ .pattern = "!a.txt" },
    };
    var q = try search.TextQuery.initWithOptions(allocator, "needle", &.{root}, "", "", &.{}, .{
        .exclude_entries = &entries,
    });
    defer q.deinit();
    var exceptions = try runQuery(allocator, &service, &q);
    defer exceptions.deinit();
    try std.testing.expectEqual(@as(usize, 5), exceptions.files.len);
    var saw_keep = false;
    var saw_types = false;
    for (exceptions.files) |file| {
        if (std.mem.endsWith(u8, file.path, "build/keep.txt")) saw_keep = true;
        if (std.mem.endsWith(u8, file.path, "node_modules/@types/index.d.ts")) saw_types = true;
        try std.testing.expect(!std.mem.endsWith(u8, file.path, "build/drop.txt"));
        try std.testing.expect(!std.mem.endsWith(u8, file.path, "node_modules/other.txt"));
    }
    try std.testing.expect(saw_keep and saw_types);

    var sibling_tmp = std.testing.tmpDir(.{});
    defer sibling_tmp.cleanup();
    try writeFile(&sibling_tmp, io, "site.css", "needle\n");
    try writeFile(&sibling_tmp, io, "site.less", "needle\n");
    var sibling_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sibling_root_len = try sibling_tmp.dir.realPath(io, &sibling_root_buffer);
    const sibling_root = sibling_root_buffer[0..sibling_root_len];
    const sibling_context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{sibling_root});
    defer sibling_context.deinit();
    var sibling_service = SearchService.init(allocator, io, sibling_context, .{ .context = undefined, .read = null });
    const sibling_entries = [_]@import("../../../../../base/common/glob.zig").ExcludeEntry{
        .{ .pattern = "*.css", .when = "$(basename).less" },
    };
    var sibling_query = try search.TextQuery.initWithOptions(allocator, "needle", &.{sibling_root}, "**/site*", "", &.{}, .{
        .exclude_entries = &sibling_entries,
    });
    defer sibling_query.deinit();
    var sibling_result = try runQuery(allocator, &sibling_service, &sibling_query);
    defer sibling_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), sibling_result.files.len);
    try std.testing.expect(std.mem.endsWith(u8, sibling_result.files[0].path, "site.less"));
}

test "TextSearch: nested workspace roots are not searched twice" {
    if (!rgAvailable(std.testing.allocator)) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(&tmp, io, "a.txt", "needle\n");
    try writeFile(&tmp, io, "nested/b.txt", "needle\n");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const nested = try std.fs.path.join(allocator, &.{ root, "nested" });
    defer allocator.free(nested);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{ root, nested });
    defer context.deinit();
    var service = SearchService.init(allocator, io, context, .{ .context = undefined, .read = null });

    var q = try makeQuery(allocator, "needle", &.{ root, nested }, .{});
    defer q.deinit();
    var result = try runQuery(allocator, &service, &q);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.files.len);
}

fn fixturesRoot(allocator: Allocator) !?[]u8 {
    if (!rgAvailable(allocator)) return null;
    const resolved = Io.Dir.cwd().realPathFileAlloc(std.testing.io, "vscode/src/vs/workbench/services/search/test/node/fixtures", allocator) catch return null;
    defer allocator.free(resolved);
    return try allocator.dupe(u8, resolved);
}

test "TextSearch: upstream fixtures, UTF-16 and Unicode ranges" {
    const allocator = std.testing.allocator;
    const root_value = try fixturesRoot(allocator) orelse return error.SkipZigTest;
    defer allocator.free(root_value);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root_value});
    defer context.deinit();
    var service = SearchService.init(allocator, std.testing.io, context, .{ .context = undefined, .read = null });

    var q = try makeQuery(allocator, "GameOfLife", &.{root_value}, .{});
    defer q.deinit();
    var result = try runQuery(allocator, &service, &q);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), result.match_count);

    try replaceOwned(allocator, &q.pattern, "Helvetica");
    var utf16 = try runQuery(allocator, &service, &q);
    defer utf16.deinit();
    try std.testing.expectEqual(@as(usize, 3), utf16.match_count);

    try replaceOwned(allocator, &q.pattern, "语");
    var unicode = try runQuery(allocator, &service, &q);
    defer unicode.deinit();
    try std.testing.expectEqual(@as(usize, 1), unicode.match_count);
}

test "TextSearch: invalid regex is rejected before starting" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const context = try WorkspaceContextService.initEmpty(allocator, "test");
    defer context.deinit();
    var service = SearchService.init(allocator, io, context, .{ .context = undefined, .read = null });
    var q = try search.TextQuery.init(allocator, "(", &.{}, "", "", &.{});
    defer q.deinit();
    q.is_regex = true;
    try std.testing.expectError(error.InvalidSearchPattern, service.startTextSearch(&q));
}

test "TextSearch: cancellation kills a sleeping rg" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var script_file = try tmp.dir.createFile(io, "sleep-rg.sh", .{});
    try script_file.writeStreamingAll(io, "#!/bin/sh\nsleep 5\n");
    try script_file.setPermissions(io, .executable_file);
    script_file.close(io);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const script_path = try std.fs.path.join(allocator, &.{ root, "sleep-rg.sh" });
    defer allocator.free(script_path);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    var service = SearchService.initWithOptions(allocator, io, context, .{ .context = undefined, .read = null }, .{
        .rg_path = script_path,
    });

    var q = try makeQuery(allocator, "needle", &.{root}, .{});
    defer q.deinit();
    var job = try service.startTextSearch(&q);
    const started = @import("../../../../../base/common/timeCompat.zig").milliTimestamp();
    job.cancel(job.context);
    job.deinit(job.context);
    const elapsed = @import("../../../../../base/common/timeCompat.zig").milliTimestamp() - started;
    try std.testing.expect(elapsed < 2000);
}

test "TextSearch: symlink loop retries without following" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var script_file = try tmp.dir.createFile(io, "loop-rg.sh", .{});
    try script_file.writeStreamingAll(io,
        \\#!/bin/sh
        \\case " $* " in
        \\  *" --follow "*)
        \\    i=0
        \\    while [ $i -le 1000 ]; do
        \\      echo "rg: File system loop found: ./loop points to an ancestor ." >&2
        \\      i=$((i + 1))
        \\    done
        \\    exit 2
        \\    ;;
        \\esac
        \\printf '%s\n' '{"type":"match","data":{"path":{"text":"a.txt"},"lines":{"text":"needle\n"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"needle"},"start":0,"end":6}]}}'
        \\
    );
    try script_file.setPermissions(io, .executable_file);
    script_file.close(io);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const script_path = try std.fs.path.join(allocator, &.{ root, "loop-rg.sh" });
    defer allocator.free(script_path);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    var service = SearchService.initWithOptions(allocator, io, context, .{ .context = undefined, .read = null }, .{
        .rg_path = script_path,
    });

    var q = try makeQuery(allocator, "needle", &.{root}, .{});
    defer q.deinit();
    var result = try runQuery(allocator, &service, &q);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.match_count);
    var warning = false;
    for (result.messages) |message| {
        if (std.mem.indexOf(u8, message.text, "Symbolic links") != null) warning = true;
    }
    try std.testing.expect(warning);
}

test "TextSearch: upstream fixture result counts" {
    const allocator = std.testing.allocator;
    const root_value = try fixturesRoot(allocator) orelse return error.SkipZigTest;
    defer allocator.free(root_value);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root_value});
    defer context.deinit();
    var service = SearchService.init(allocator, std.testing.io, context, .{ .context = undefined, .read = null });

    const Case = struct {
        pattern: []const u8,
        count: usize,
        is_regex: bool = false,
        is_word: bool = false,
        include: []const u8 = "",
        exclude: []const u8 = "",
        max: usize = search.DEFAULT_MAX_SEARCH_RESULTS,
        requires_pcre2: bool = false,
    };
    const pcre2 = rgSupportsPcre2(allocator);
    const cases = [_]Case{
        .{ .pattern = "GameOfLife", .count = 4 },
        .{ .pattern = "Game.?fL\\w?fe", .count = 4, .is_regex = true },
        .{ .pattern = "G\\u{0061}m\\u0065OfLife", .count = 4, .is_regex = true },
        .{ .pattern = "Life(?!P)", .count = 8, .is_regex = true, .requires_pcre2 = true },
        .{ .pattern = "GameOfLife.*", .count = 4, .is_regex = true },
        .{ .pattern = "GameOfLife", .count = 4, .is_word = true },
        .{ .pattern = " GameOfLife ", .count = 1, .is_word = true },
        .{ .pattern = ", as =", .count = 1, .is_word = true },
        .{ .pattern = "e", .count = 785 },
        .{ .pattern = "e", .count = 391, .exclude = "**/examples" },
        .{ .pattern = "e", .count = 414, .exclude = "**/examples,!examples/small.js" },
        .{ .pattern = "e", .count = 394, .include = "**/examples/**" },
        .{ .pattern = "e", .count = 371, .include = "**/examples/**", .exclude = "**/examples/small.js" },
        .{ .pattern = "a", .count = 520, .max = 520 },
        .{ .pattern = "ahsogehtdas", .count = 0 },
        .{ .pattern = "-size", .count = 9 },
    };
    for (cases) |case| {
        if (case.requires_pcre2 and !pcre2) continue;
        var q = try search.TextQuery.initWithOptions(allocator, case.pattern, &.{root_value}, case.include, case.exclude, &.{}, .{
            .max_results = case.max,
        });
        defer q.deinit();
        q.is_regex = case.is_regex;
        q.is_word_match = case.is_word;
        var result = try runQuery(allocator, &service, &q);
        defer result.deinit();
        try std.testing.expectEqual(case.count, result.match_count);
    }

    var unicode = try makeQuery(allocator, "语", &.{root_value}, .{});
    defer unicode.deinit();
    var unicode_result = try runQuery(allocator, &service, &unicode);
    defer unicode_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), unicode_result.match_count);
}

test "TextSearch: upstream context, multi-match and Unicode ranges" {
    const allocator = std.testing.allocator;
    const root_value = try fixturesRoot(allocator) orelse return error.SkipZigTest;
    defer allocator.free(root_value);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root_value});
    defer context.deinit();
    var service = SearchService.init(allocator, std.testing.io, context, .{ .context = undefined, .read = null });

    var context_query = try search.TextQuery.initWithOptions(allocator, "compiler.typeCheck();", &.{root_value}, "", "", &.{}, .{
        .surrounding_context = 1,
    });
    defer context_query.deinit();
    var context_result = try runQuery(allocator, &service, &context_query);
    defer context_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), context_result.match_count);
    try std.testing.expectEqual(@as(usize, 1), context_result.files.len);
    try std.testing.expectEqual(@as(usize, 2), context_result.files[0].contexts.len);
    try std.testing.expectEqual(@as(usize, 24), context_result.files[0].contexts[0].line_number);
    try std.testing.expectEqualStrings("        compiler.addUnit(prog,\"input.ts\");", context_result.files[0].contexts[0].text);
    try std.testing.expectEqual(@as(usize, 26), context_result.files[0].contexts[1].line_number);
    try std.testing.expectEqualStrings("        compiler.emit();", context_result.files[0].contexts[1].text);

    var multi = try search.TextQuery.initWithOptions(allocator, "h\\d,", &.{root_value}, "", "", &.{}, .{});
    defer multi.deinit();
    multi.is_regex = true;
    var multi_result = try runQuery(allocator, &service, &multi);
    defer multi_result.deinit();
    try std.testing.expectEqual(@as(usize, 15), multi_result.match_count);
    try std.testing.expectEqual(@as(usize, 3), multi_result.files.len);
    try std.testing.expectEqual(@as(usize, 5), multi_result.files[0].first_ranges);

    var unicode = try makeQuery(allocator, "语", &.{root_value}, .{});
    defer unicode.deinit();
    var unicode_result = try runQuery(allocator, &service, &unicode);
    defer unicode_result.deinit();
    const source = unicode_result.files[0].first_source.?;
    try std.testing.expectEqual(@as(usize, 0), source.start_line_number);
    try std.testing.expectEqual(@as(usize, 1), source.start_column);
    try std.testing.expectEqual(@as(usize, 2), source.end_column);
}

test "TextSearch: multiroot fixtures and global excludes" {
    const allocator = std.testing.allocator;
    const fixtures = try fixturesRoot(allocator) orelse return error.SkipZigTest;
    defer allocator.free(fixtures);
    const examples = try std.fs.path.join(allocator, &.{ fixtures, "examples" });
    defer allocator.free(examples);
    const more = try std.fs.path.join(allocator, &.{ fixtures, "more" });
    defer allocator.free(more);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{ examples, more });
    defer context.deinit();
    var service = SearchService.init(allocator, std.testing.io, context, .{ .context = undefined, .read = null });

    var conway = try makeQuery(allocator, "conway", &.{ examples, more }, .{});
    defer conway.deinit();
    var conway_result = try runQuery(allocator, &service, &conway);
    defer conway_result.deinit();
    try std.testing.expectEqual(@as(usize, 8), conway_result.match_count);

    var e = try makeQuery(allocator, "e", &.{ examples, more }, .{});
    defer e.deinit();
    try replaceOwned(allocator, &e.exclude_pattern, "**/*.txt");
    var e_txt = try runQuery(allocator, &service, &e);
    defer e_txt.deinit();
    try std.testing.expectEqual(@as(usize, 394), e_txt.match_count);

    try replaceOwned(allocator, &e.exclude_pattern, "**/*.txt,**/*.js");
    var e_none = try runQuery(allocator, &service, &e);
    defer e_none.deinit();
    try std.testing.expectEqual(@as(usize, 0), e_none.match_count);
}

test "TextSearch: filtered exclude exceptions do not consume the limit" {
    const allocator = std.testing.allocator;
    const fixtures = try fixturesRoot(allocator) orelse return error.SkipZigTest;
    defer allocator.free(fixtures);
    const examples = try std.fs.path.join(allocator, &.{ fixtures, "examples" });
    defer allocator.free(examples);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{fixtures});
    defer context.deinit();
    var service = SearchService.init(allocator, std.testing.io, context, .{ .context = undefined, .read = null });

    var q = try search.TextQuery.initWithOptions(allocator, "e", &.{fixtures}, "examples/employee.js", "examples,!examples", &.{}, .{
        .max_results = 1,
    });
    defer q.deinit();
    var result = try runQuery(allocator, &service, &q);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.match_count);
    try std.testing.expect(result.limit_hit);
}
