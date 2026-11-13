// Port of the terminal workspace text-search engine used by the Search view.
//
// Upstream `ISearchService.textSearch` is backed by ripgrep and streams
// `IFileMatch` values. The terminal has no external search process, so this
// implementation walks workspace folders with `std.Io.Dir`, reads UTF-8 files,
// and runs the ported editor regex/word classifier. It keeps the upstream
// streaming contract through an incremental job: each `step` scans a bounded
// number of files and returns owned file matches.
//
// `.gitignore` and `.ignore` files are honored through the ported `IgnoreFile`:
// every directory's ignore file inherits the enclosing one, so negations and
// nested ignore files behave like git. Fixed excludes for version control
// metadata and Zig build output remain, `search.exclude`/`files.exclude`
// configuration is not ported, and symlinks, binary files, invalid UTF-8 and
// files larger than 10 MB are skipped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const search = @import("search.zig");
const TextQuery = search.TextQuery;
const TextSearchMatch = search.TextSearchMatch;
const SearchRange = search.SearchRange;
const SearchFileResult = search.SearchFileResult;
const SearchStep = search.SearchStep;
const FileContentProvider = search.FileContentProvider;
const ISearchJob = search.ISearchJob;
const ISearchService = search.ISearchService;
const glob = @import("../../../../base/common/glob.zig").GlobList;
const ignore_file_module = @import("ignoreFile.zig");
const IgnoreFile = ignore_file_module.IgnoreFile;
const ignore_file_names = ignore_file_module.ignore_file_names;
const workspace_context = @import("../../../services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const text_model_search = @import("../../../../editor/common/model/textModelSearch.zig");
const SearchParams = text_model_search.SearchParams;
const Searcher = text_model_search.Searcher;
const SearchData = @import("../../../../editor/common/model.zig").SearchData;
const DefaultWordSeparators = @import("../../../../editor/common/core/wordCharacterClassifier.zig").DefaultWordSeparators;
const WordCharacterClassifier = @import("../../../../editor/common/core/wordCharacterClassifier.zig").WordCharacterClassifier;

pub const MAX_FILE_SIZE: usize = 10 * 1024 * 1024;
pub const MAX_ENTRIES: usize = 100_000;
pub const MAX_IGNORE_FILE_SIZE: usize = 1024 * 1024;

const excluded_directories = [_][]const u8{
    ".git",         ".hg",        ".svn",
    "node_modules", ".zig-cache", "zig-cache",
    "zig-out",
};

const QueueEntry = struct {
    path: []u8,
    root_index: usize,
    is_file: bool,
    /// Ignore chain that applies to the entry itself, i.e. the chain of the
    /// directory that contains it.
    ignore: ?*const IgnoreFile = null,
};

const extra_root_sentinel = std.math.maxInt(usize);

pub const SearchService = struct {
    allocator: Allocator,
    io: Io,
    workspace: *WorkspaceContextService,
    provider: FileContentProvider,

    pub fn init(
        allocator: Allocator,
        io: Io,
        workspace: *WorkspaceContextService,
        provider: FileContentProvider,
    ) SearchService {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace = workspace,
            .provider = provider,
        };
    }

    pub fn startTextSearch(self: *SearchService, query: *const TextQuery) !ISearchJob {
        const job = try SearchJob.init(self, query);
        return job.interface();
    }

    pub fn interface(self: *SearchService) ISearchService {
        return .{ .context = self, .start_text_search = startTextSearchCallback };
    }
};

fn startTextSearchCallback(
    context: *anyopaque,
    query: *const TextQuery,
) anyerror!ISearchJob {
    const self: *SearchService = @ptrCast(@alignCast(context));
    return self.startTextSearch(query);
}

const SearchJob = struct {
    allocator: Allocator,
    io: Io,
    workspace: *WorkspaceContextService,
    provider: FileContentProvider,
    query: *const TextQuery,
    search_data: SearchData,
    word_classifier: ?WordCharacterClassifier = null,
    include_list: glob,
    exclude_list: glob,
    queue: std.array_list.Managed(QueueEntry),
    /// Owns every ignore file loaded during the walk; a child points at its
    /// parent, so the chain stays valid until the job is deinitialized.
    ignore_files: std.array_list.Managed(*IgnoreFile),
    queue_index: usize = 0,
    done: bool = false,
    cancelled: bool = false,
    limit_hit: bool = false,
    total_matches: usize = 0,

    fn init(service: *SearchService, query: *const TextQuery) !*SearchJob {
        const self = try service.allocator.create(SearchJob);
        errdefer service.allocator.destroy(self);

        var params = SearchParams.init(
            query.pattern,
            query.is_regex,
            query.is_case_sensitive,
            null,
        );
        const search_data = (try params.parseSearchRequest(service.allocator)) orelse
            return error.InvalidSearchPattern;

        self.* = .{
            .allocator = service.allocator,
            .io = service.io,
            .workspace = service.workspace,
            .provider = service.provider,
            .query = query,
            .search_data = search_data,
            .include_list = try glob.init(service.allocator, query.include_pattern),
            .exclude_list = try glob.init(service.allocator, query.exclude_pattern),
            .queue = std.array_list.Managed(QueueEntry).init(service.allocator),
            .ignore_files = std.array_list.Managed(*IgnoreFile).init(service.allocator),
        };
        if (query.is_word_match) {
            self.word_classifier = try WordCharacterClassifier.init(service.allocator, DefaultWordSeparators);
            self.search_data.wordSeparators = &self.word_classifier.?;
        }
        errdefer {
            self.search_data.regex.deinit();
            if (self.word_classifier) |*classifier| classifier.deinit();
            self.include_list.deinit();
            self.exclude_list.deinit();
            self.queue.deinit();
            for (self.ignore_files.items) |ignore_file| ignore_file.deinit();
            self.ignore_files.deinit();
        }

        // Explicit extra files first; workspace folders follow. This mirrors
        // upstream's sync open-editor results and lets a search in an empty
        // workspace still find open files.
        var added_extras = std.StringHashMap(void).init(service.allocator);
        defer added_extras.deinit();
        for (query.extra_files) |path| {
            if (self.isInsideWorkspace(path)) continue;
            if (added_extras.contains(path)) continue;
            try added_extras.put(path, {});
            try self.enqueue(path, extra_root_sentinel, true, null);
        }
        for (query.folder_queries, 0..) |folder_query, index| {
            try self.enqueue(folder_query.folder, index, false, null);
        }

        if (self.queue.items.len == 0) self.done = true;
        return self;
    }

    fn enqueue(
        self: *SearchJob,
        path: []const u8,
        root_index: usize,
        is_file: bool,
        ignore: ?*const IgnoreFile,
    ) !void {
        if (self.queue.items.len >= MAX_ENTRIES) {
            self.limit_hit = true;
            return;
        }
        const copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(copy);
        try self.queue.append(.{
            .path = copy,
            .root_index = root_index,
            .is_file = is_file,
            .ignore = ignore,
        });
    }

    fn isInsideWorkspace(self: *const SearchJob, path: []const u8) bool {
        for (self.query.folder_paths) |folder| {
            if (pathIsInside(folder, path)) return true;
        }
        return false;
    }

    fn interface(self: *SearchJob) ISearchJob {
        return .{
            .context = self,
            .step = stepCallback,
            .cancel = cancelCallback,
            .deinit = deinitCallback,
        };
    }

    fn stepCallback(
        context: *anyopaque,
        allocator: Allocator,
        max_files: usize,
    ) anyerror!SearchStep {
        const self: *SearchJob = @ptrCast(@alignCast(context));
        return self.step(allocator, max_files);
    }

    fn cancelCallback(context: *anyopaque) void {
        const self: *SearchJob = @ptrCast(@alignCast(context));
        self.cancelled = true;
    }

    fn deinitCallback(context: *anyopaque) void {
        const self: *SearchJob = @ptrCast(@alignCast(context));
        self.deinit();
    }

    fn deinit(self: *SearchJob) void {
        for (self.queue.items) |entry| self.allocator.free(entry.path);
        self.queue.deinit();
        for (self.ignore_files.items) |ignore_file| ignore_file.deinit();
        self.ignore_files.deinit();
        self.include_list.deinit();
        self.exclude_list.deinit();
        self.search_data.regex.deinit();
        if (self.word_classifier) |*classifier| classifier.deinit();
        self.allocator.destroy(self);
    }

    fn step(self: *SearchJob, allocator: Allocator, max_files: usize) !SearchStep {
        if (self.cancelled or self.done) {
            return .{ .results = try allocator.alloc(SearchFileResult, 0), .done = true, .limit_hit = self.limit_hit };
        }

        var results = std.array_list.Managed(SearchFileResult).init(allocator);
        errdefer {
            for (results.items) |*result| result.deinit();
            results.deinit();
        }

        var files_examined: usize = 0;
        var operations: usize = 0;
        const max_operations = @max(max_files * 8, 64);
        while (files_examined < max_files and operations < max_operations and !self.done) {
            operations += 1;
            if (self.queue_index >= self.queue.items.len) {
                self.done = true;
                break;
            }
            const entry = self.queue.items[self.queue_index];
            self.queue_index += 1;

            if (entry.is_file) {
                files_examined += 1;
                if (try self.searchFile(allocator, entry)) |file_result| {
                    try results.append(file_result);
                }
            } else {
                self.scanDirectory(entry) catch {};
            }
            if (self.total_matches >= self.query.max_results) {
                self.limit_hit = true;
                self.done = true;
            }
        }

        if (self.queue_index >= self.queue.items.len) self.done = true;
        if (self.cancelled) self.done = true;
        return .{
            .results = try results.toOwnedSlice(),
            .done = self.done,
            .limit_hit = self.limit_hit,
        };
    }

    fn scanDirectory(self: *SearchJob, entry: QueueEntry) !void {
        var dir = Io.Dir.cwd().openDir(self.io, entry.path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        // The ignore file of this directory excludes its children.
        const ignore = try self.loadIgnoreFiles(entry.path, entry.ignore);

        var iterator = dir.iterate();
        while (iterator.next(self.io) catch null) |child| {
            if (std.mem.eql(u8, child.name, ".") or std.mem.eql(u8, child.name, "..")) continue;
            if (self.queue.items.len >= MAX_ENTRIES) {
                self.limit_hit = true;
                return;
            }
            const path = try std.fs.path.join(self.allocator, &.{ entry.path, child.name });
            defer self.allocator.free(path);
            switch (child.kind) {
                .sym_link => continue,
                .directory => {
                    if (isExcludedDirectory(child.name)) continue;
                    // `isPathIncludedInTraversal` does not check the parent
                    // directories; the walk already did when it descended.
                    if (!ignore_file_module.isPathIncluded(ignore, path, true)) continue;
                    try self.enqueue(path, entry.root_index, false, ignore);
                },
                .file => {
                    if (!ignore_file_module.isPathIncluded(ignore, path, false)) continue;
                    try self.enqueue(path, entry.root_index, true, ignore);
                },
                else => continue,
            }
        }
    }

    /// Loads `<directory>/.gitignore` and then `<directory>/.ignore` on top of
    /// `parent` and returns the innermost ignore file, which applies to the
    /// contents of `directory`.
    fn loadIgnoreFiles(
        self: *SearchJob,
        directory: []const u8,
        parent: ?*const IgnoreFile,
    ) !?*const IgnoreFile {
        var current = parent;
        for (ignore_file_names) |name| {
            const path = try std.fs.path.join(self.allocator, &.{ directory, name });
            defer self.allocator.free(path);
            const contents = Io.Dir.cwd().readFileAlloc(
                self.io,
                path,
                self.allocator,
                .limited(MAX_IGNORE_FILE_SIZE),
            ) catch continue;
            defer self.allocator.free(contents);

            const ignore_file = try IgnoreFile.init(
                self.allocator,
                contents,
                directory,
                current,
                false,
            );
            errdefer ignore_file.deinit();
            try self.ignore_files.append(ignore_file);
            current = ignore_file;
        }
        return current;
    }

    fn searchFile(self: *SearchJob, allocator: Allocator, entry: QueueEntry) !?SearchFileResult {
        if (self.total_matches >= self.query.max_results) return null;

        const relative = self.relativePath(entry);
        if (!self.include_list.isEmpty()) {
            if (!self.include_list.hasPositiveRule() or !self.include_list.matches(relative)) return null;
        }
        if (!self.exclude_list.isEmpty() and self.exclude_list.matches(relative)) return null;

        const content = self.readContent(entry.path) orelse return null;
        defer self.allocator.free(content);

        const text = normalizeContent(self.allocator, content) catch return null;
        defer self.allocator.free(text);
        if (text.len == 0) return null;
        if (!std.unicode.utf8ValidateSlice(text)) return null;

        const line_starts = try collectLineStarts(self.allocator, text);
        defer self.allocator.free(line_starts);

        var results = std.array_list.Managed(TextSearchMatch).init(allocator);
        errdefer {
            for (results.items) |*result| result.deinit();
            results.deinit();
        }

        var ranges = std.array_list.Managed(SearchRange).init(self.allocator);
        defer ranges.deinit();
        var current_line: ?usize = null;

        var searcher = Searcher.init(self.search_data.wordSeparators, &self.search_data.regex, text, 0);
        while (searcher.next()) |found| {
            defer found.deinit();
            const start = found.index();
            const end = start + found.length();
            const start_pos = positionAt(line_starts, start);
            const end_pos = positionAt(line_starts, end);

            if (start_pos.line != end_pos.line) {
                if (current_line != null) {
                    try self.flushLine(allocator, text, line_starts, current_line.?, &ranges, &results);
                    ranges.clearRetainingCapacity();
                    current_line = null;
                }
                const start_line = lineStart(line_starts, start_pos.line);
                const end_line_end = lineEnd(text, line_starts, end_pos.line);
                if (end_line_end >= start_line) {
                    const snippet = text[start_line..end_line_end];
                    const source = SearchRange.init(
                        start_pos.line,
                        start - start_line,
                        end_pos.line,
                        end - lineStart(line_starts, end_pos.line),
                    );
                    const one = [_]SearchRange{source};
                    try results.append(try TextSearchMatch.init(allocator, snippet, &one, self.query.preview));
                    self.total_matches += 1;
                }
            } else {
                if (current_line == null or current_line.? != start_pos.line) {
                    if (current_line != null) {
                        try self.flushLine(allocator, text, line_starts, current_line.?, &ranges, &results);
                        ranges.clearRetainingCapacity();
                    }
                    current_line = start_pos.line;
                }
                try ranges.append(SearchRange.init(
                    start_pos.line,
                    start - lineStart(line_starts, start_pos.line),
                    end_pos.line,
                    end - lineStart(line_starts, end_pos.line),
                ));
                self.total_matches += 1;
            }

            if (self.total_matches >= self.query.max_results) {
                self.limit_hit = true;
                break;
            }
        }
        if (current_line != null) {
            try self.flushLine(allocator, text, line_starts, current_line.?, &ranges, &results);
        }

        if (results.items.len == 0) {
            results.deinit();
            return null;
        }

        return .{
            .allocator = allocator,
            .resource = try allocator.dupe(u8, entry.path),
            .results = try results.toOwnedSlice(),
        };
    }

    fn flushLine(
        self: *SearchJob,
        allocator: Allocator,
        text: []const u8,
        line_starts: []const usize,
        line_index: usize,
        ranges: *std.array_list.Managed(SearchRange),
        results: *std.array_list.Managed(TextSearchMatch),
    ) !void {
        if (ranges.items.len == 0) return;
        const start = lineStart(line_starts, line_index);
        const end = lineEnd(text, line_starts, line_index);
        try results.append(try TextSearchMatch.init(
            allocator,
            text[start..end],
            ranges.items,
            self.query.preview,
        ));
    }

    fn relativePath(self: *const SearchJob, entry: QueueEntry) []const u8 {
        if (entry.root_index == extra_root_sentinel or entry.root_index >= self.query.folder_paths.len) {
            return std.fs.path.basename(entry.path);
        }
        const root = self.query.folder_paths[entry.root_index];
        if (std.mem.startsWith(u8, entry.path, root)) {
            var index = root.len;
            if (index < entry.path.len and entry.path[index] == '/') index += 1;
            return entry.path[index..];
        }
        return entry.path;
    }

    fn readContent(self: *SearchJob, path: []const u8) ?[]u8 {
        if (self.provider.read) |read| {
            if (read(self.provider.context, self.allocator, path) catch null) |content| {
                if (content.len > MAX_FILE_SIZE or hasNulByte(content)) {
                    self.allocator.free(content);
                    return null;
                }
                return content;
            }
        }
        const content = Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(MAX_FILE_SIZE),
        ) catch return null;
        if (hasNulByte(content)) {
            self.allocator.free(content);
            return null;
        }
        return content;
    }
};

const Position = struct { line: usize, column: usize };

fn positionAt(line_starts: []const usize, offset: usize) Position {
    var low: usize = 0;
    var high: usize = line_starts.len;
    while (low + 1 < high) {
        const mid = (low + high) / 2;
        if (line_starts[mid] <= offset) low = mid else high = mid;
    }
    return .{ .line = low, .column = offset - line_starts[low] };
}

fn lineStart(line_starts: []const usize, line: usize) usize {
    if (line >= line_starts.len) return line_starts[line_starts.len - 1];
    return line_starts[line];
}

fn lineEnd(text: []const u8, line_starts: []const usize, line: usize) usize {
    if (line + 1 < line_starts.len) return line_starts[line + 1] - 1;
    return text.len;
}

fn collectLineStarts(allocator: Allocator, text: []const u8) ![]usize {
    var starts = std.array_list.Managed(usize).init(allocator);
    errdefer starts.deinit();
    try starts.append(0);
    for (text, 0..) |ch, index| {
        if (ch == '\n') try starts.append(index + 1);
    }
    return try starts.toOwnedSlice();
}

fn normalizeContent(allocator: Allocator, content: []const u8) ![]u8 {
    var start: usize = 0;
    if (content.len >= 3 and content[0] == 0xef and content[1] == 0xbb and content[2] == 0xbf) start = 3;
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var index = start;
    while (index < content.len) : (index += 1) {
        const ch = content[index];
        if (ch == '\r') {
            if (index + 1 < content.len and content[index + 1] == '\n') index += 1;
            try out.append('\n');
        } else {
            try out.append(ch);
        }
    }
    return try out.toOwnedSlice();
}

fn hasNulByte(content: []const u8) bool {
    const limit = @min(content.len, 8192);
    return std.mem.indexOfScalar(u8, content[0..limit], 0) != null;
}

fn isExcludedDirectory(name: []const u8) bool {
    for (excluded_directories) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn pathIsInside(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root.len == 0 or root[root.len - 1] == '/') return true;
    return path[root.len] == '/';
}

test "SearchService: streams plain, regex and word matches" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "a.txt", .{});
    try file.writeStreamingAll(io, "alpha beta\ngamma alpha\n");
    file.close(io);
    var binary = try tmp.dir.createFile(io, "b.bin", .{});
    try binary.writeStreamingAll(io, "al\x00pha");
    binary.close(io);
    try tmp.dir.createDirPath(io, ".git");
    var ignored = try tmp.dir.createFile(io, ".git/ignored.txt", .{});
    try ignored.writeStreamingAll(io, "alpha");
    ignored.close(io);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();

    const provider = FileContentProvider{
        .context = undefined,
        .read = null,
        .extra_files = null,
        .free_paths = null,
    };
    var service = SearchService.init(allocator, io, context, provider);
    var query = try TextQuery.init(allocator, "alpha", &.{root}, "", "", &.{});
    defer query.deinit();

    var job = try service.startTextSearch(&query);
    defer job.deinit(job.context);

    var saw = false;
    while (true) {
        const step = try job.step(job.context, allocator, 10);
        defer {
            for (step.results) |*result| result.deinit();
            allocator.free(step.results);
        }
        for (step.results) |result| {
            if (std.mem.endsWith(u8, result.resource, "a.txt")) {
                saw = true;
                try std.testing.expectEqual(@as(usize, 2), result.results.len);
            }
            try std.testing.expect(!std.mem.endsWith(u8, result.resource, "b.bin"));
            try std.testing.expect(!std.mem.endsWith(u8, result.resource, "ignored.txt"));
        }
        if (step.done) break;
    }
    try std.testing.expect(saw);
}

const CountResult = struct { matches: usize, limit_hit: bool };

fn runQuery(service: *SearchService, query: *const TextQuery, allocator: Allocator) !CountResult {
    var job = try service.startTextSearch(query);
    defer job.deinit(job.context);
    var count: usize = 0;
    var limit_hit = false;
    while (true) {
        const step = try job.step(job.context, allocator, 32);
        defer {
            for (step.results) |*result| result.deinit();
            allocator.free(step.results);
        }
        for (step.results) |result| {
            for (result.results) |text_match| count += text_match.range_locations.len;
        }
        limit_hit = limit_hit or step.limit_hit;
        if (step.done) break;
    }
    return .{ .matches = count, .limit_hit = limit_hit };
}

test "SearchService: case, word, regex, include/exclude and limit" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "words.txt", .{});
    try file.writeStreamingAll(io, "Alpha alpha ALPHA alphabet\n");
    file.close(io);
    var markdown = try tmp.dir.createFile(io, "other.md", .{});
    try markdown.writeStreamingAll(io, "alpha\n");
    markdown.close(io);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    var service = SearchService.init(allocator, io, context, .{
        .context = undefined,
        .read = null,
        .extra_files = null,
        .free_paths = null,
    });

    var q = try TextQuery.init(allocator, "alpha", &.{root}, "", "", &.{});
    defer q.deinit();
    q.is_case_sensitive = true;
    var result = try runQuery(&service, &q, allocator);
    try std.testing.expectEqual(@as(usize, 3), result.matches);

    q.is_case_sensitive = false;
    q.is_word_match = true;
    result = try runQuery(&service, &q, allocator);
    try std.testing.expectEqual(@as(usize, 4), result.matches);

    q.is_word_match = false;
    q.is_regex = true;
    try replaceOwned(allocator, &q.pattern, "a\\w+");
    result = try runQuery(&service, &q, allocator);
    try std.testing.expect(result.matches >= 5);

    q.is_regex = false;
    try replaceOwned(allocator, &q.pattern, "alpha");
    q.max_results = 1;
    result = try runQuery(&service, &q, allocator);
    try std.testing.expectEqual(@as(usize, 1), result.matches);
    try std.testing.expect(result.limit_hit);

    q.max_results = 20000;
    try replaceOwned(allocator, &q.include_pattern, "**/*.md");
    result = try runQuery(&service, &q, allocator);
    try std.testing.expectEqual(@as(usize, 1), result.matches);

    try replaceOwned(allocator, &q.include_pattern, "");
    try replaceOwned(allocator, &q.exclude_pattern, "**/*.txt");
    result = try runQuery(&service, &q, allocator);
    try std.testing.expectEqual(@as(usize, 1), result.matches);
}

fn replaceOwned(allocator: Allocator, field: *[]u8, value: []const u8) !void {
    const copy = try allocator.dupe(u8, value);
    allocator.free(field.*);
    field.* = copy;
}

fn writeTestFile(tmp: *std.testing.TmpDir, io: Io, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| try tmp.dir.createDirPath(io, directory);
    var file = try tmp.dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

test "SearchService: honors .gitignore and .ignore files" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(&tmp, io, "kept.txt", "alpha\n");
    try writeTestFile(&tmp, io, "ignored.txt", "alpha\n");
    try writeTestFile(&tmp, io, "other.txt", "alpha\n");
    try writeTestFile(&tmp, io, ".gitignore", "ignored.txt\n");
    try writeTestFile(&tmp, io, ".ignore", "other.txt\n");
    try writeTestFile(&tmp, io, "sub/kept.txt", "alpha\n");
    try writeTestFile(&tmp, io, "sub/ignored.txt", "alpha\n");
    try writeTestFile(&tmp, io, "sub/more.txt", "alpha\n");
    // A nested ignore file re-includes the file its parent ignores and adds a
    // pattern of its own.
    try writeTestFile(&tmp, io, "sub/.gitignore", "!ignored.txt\nmore.txt\n");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    var service = SearchService.init(allocator, io, context, .{
        .context = undefined,
        .read = null,
        .extra_files = null,
        .free_paths = null,
    });

    var q = try TextQuery.init(allocator, "alpha", &.{root}, "", "", &.{});
    defer q.deinit();

    var job = try service.startTextSearch(&q);
    defer job.deinit(job.context);

    var found = std.StringHashMap(void).init(allocator);
    defer found.deinit();
    while (true) {
        const step = try job.step(job.context, allocator, 32);
        defer {
            for (step.results) |*result| result.deinit();
            allocator.free(step.results);
        }
        for (step.results) |result| {
            var relative = result.resource;
            if (std.mem.startsWith(u8, relative, root)) {
                relative = relative[root.len..];
                if (relative.len > 0 and relative[0] == '/') relative = relative[1..];
            }
            try found.put(try allocator.dupe(u8, relative), {});
        }
        if (step.done) break;
    }
    defer {
        var keys = found.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
    }

    try std.testing.expect(found.contains("kept.txt"));
    try std.testing.expect(found.contains("sub/kept.txt"));
    try std.testing.expect(found.contains("sub/ignored.txt"));
    try std.testing.expect(!found.contains("ignored.txt"));
    try std.testing.expect(!found.contains("other.txt"));
    try std.testing.expect(!found.contains("sub/more.txt"));
}
