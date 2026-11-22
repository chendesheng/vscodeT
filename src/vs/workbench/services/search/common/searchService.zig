// Port of the terminal workspace text-search engine used by the Search view.
//
// Upstream `ISearchService.textSearch` is backed by ripgrep and streams
// `IFileMatch` values, with a synchronous pass over open editor buffers. This
// port keeps that split: open/dirty editors are searched with the ported editor
// regex matcher on the main thread, while workspace files are searched by
// `TextSearchWorker` (`rg --json`) on a background thread. Results are filtered,
// limited and published through the existing incremental `ISearchJob`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const search = @import("search.zig");
const TextQuery = search.TextQuery;
const TextSearchMatch = search.TextSearchMatch;
const TextSearchContext = search.TextSearchContext;
const SearchRange = search.SearchRange;
const RangeLocation = search.RangeLocation;
const SearchFileResult = search.SearchFileResult;
const SearchStep = search.SearchStep;
const SearchMessage = search.SearchMessage;
const FileContentProvider = search.FileContentProvider;
const ISearchJob = search.ISearchJob;
const ISearchService = search.ISearchService;
const glob_module = @import("../../../../base/common/glob.zig");
const glob = glob_module.GlobList;
const ParsedExcludeExpression = glob_module.ParsedExcludeExpression;
const workspace_context = @import("../../../services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const text_model_search = @import("../../../../editor/common/model/textModelSearch.zig");
const SearchParams = text_model_search.SearchParams;
const Searcher = text_model_search.Searcher;
const SearchData = @import("../../../../editor/common/model.zig").SearchData;
const DefaultWordSeparators = @import("../../../../editor/common/core/wordCharacterClassifier.zig").DefaultWordSeparators;
const WordCharacterClassifier = @import("../../../../editor/common/core/wordCharacterClassifier.zig").WordCharacterClassifier;
const text_worker = @import("../node/textSearchWorker.zig");
const text_engine = @import("../node/ripgrepTextSearchEngine.zig");
const TextSearchWorker = text_worker.TextSearchWorker;

pub const MAX_FILE_SIZE: usize = 10 * 1024 * 1024;

pub const Options = struct {
    /// Ripgrep executable. Tests inject a fake `rg` here.
    rg_path: []const u8 = "rg",
};

pub const SearchService = struct {
    allocator: Allocator,
    io: Io,
    workspace: *WorkspaceContextService,
    provider: FileContentProvider,
    rg_path: []const u8,

    pub fn init(
        allocator: Allocator,
        io: Io,
        workspace: *WorkspaceContextService,
        provider: FileContentProvider,
    ) SearchService {
        return initWithOptions(allocator, io, workspace, provider, .{});
    }

    pub fn initWithOptions(
        allocator: Allocator,
        io: Io,
        workspace: *WorkspaceContextService,
        provider: FileContentProvider,
        options: Options,
    ) SearchService {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace = workspace,
            .provider = provider,
            .rg_path = options.rg_path,
        };
    }

    pub fn startTextSearch(self: *SearchService, query: *const TextQuery) !ISearchJob {
        const job = try TextSearchJob.init(self, query);
        return job.interface();
    }

    pub fn interface(self: *SearchService) ISearchService {
        return .{ .context = self, .start_text_search = startTextSearchCallback };
    }
};

fn startTextSearchCallback(context: *anyopaque, query: *const TextQuery) anyerror!ISearchJob {
    const self: *SearchService = @ptrCast(@alignCast(context));
    return self.startTextSearch(query);
}

const TextSearchJob = struct {
    allocator: Allocator,
    io: Io,
    provider: FileContentProvider,
    query: *const TextQuery,
    include_list: glob,
    exclude_list: glob,
    exclude_expression: ?ParsedExcludeExpression = null,
    search_data: SearchData,
    word_classifier: ?WordCharacterClassifier = null,

    open_results: []SearchFileResult = &.{},
    open_index: usize = 0,
    open_paths: std.StringHashMap(void),
    seen_paths: std.StringHashMap(void),
    sibling_root: []const u8 = "",

    worker: ?*TextSearchWorker = null,
    done: bool = false,
    cancelled: bool = false,
    limit_hit: bool = false,
    total_matches: usize = 0,

    fn init(service: *SearchService, query: *const TextQuery) !*TextSearchJob {
        const self = try service.allocator.create(TextSearchJob);
        errdefer service.allocator.destroy(self);

        var converted_pattern: ?[]u8 = null;
        defer if (converted_pattern) |pattern| service.allocator.free(pattern);
        var search_pattern = query.pattern;
        if (query.is_regex) {
            converted_pattern = try text_engine.unicodeEscapesToPCRE2(service.allocator, query.pattern);
            search_pattern = converted_pattern.?;
        }
        var params = SearchParams.init(
            search_pattern,
            query.is_regex,
            query.is_case_sensitive,
            null,
        );
        const search_data = (try params.parseSearchRequest(service.allocator)) orelse
            return error.InvalidSearchPattern;

        self.* = .{
            .allocator = service.allocator,
            .io = service.io,
            .provider = service.provider,
            .query = query,
            .include_list = try glob.init(service.allocator, query.include_pattern),
            .exclude_list = try glob.init(service.allocator, query.exclude_pattern),
            .search_data = search_data,
            .open_paths = std.StringHashMap(void).init(service.allocator),
            .seen_paths = std.StringHashMap(void).init(service.allocator),
        };
        errdefer {
            self.include_list.deinit();
            self.exclude_list.deinit();
            if (self.exclude_expression) |*expression| expression.deinit();
            self.search_data.regex.deinit();
            if (self.word_classifier) |*classifier| classifier.deinit();
            const emitted = @min(self.open_index, self.open_results.len);
            for (self.open_results[emitted..]) |*result| result.deinit();
            if (self.open_results.len > 0) self.allocator.free(self.open_results);
            freeMapKeys(self.allocator, &self.open_paths);
            freeMapKeys(self.allocator, &self.seen_paths);
            self.open_paths.deinit();
            self.seen_paths.deinit();
        }

        if (query.exclude_entries.len > 0) {
            self.exclude_expression = try ParsedExcludeExpression.init(service.allocator, query.exclude_entries, .{
                .ignore_case = query.ignore_glob_case,
            });
        }
        if (query.is_word_match) {
            self.word_classifier = try WordCharacterClassifier.init(service.allocator, DefaultWordSeparators);
            self.search_data.wordSeparators = &self.word_classifier.?;
        }

        try self.searchOpenBuffers();
        if (!self.limit_hit and self.total_matches < query.max_results) {
            self.worker = try TextSearchWorker.init(service.allocator, query, service.rg_path);
        }
        return self;
    }

    fn interface(self: *TextSearchJob) ISearchJob {
        return .{
            .context = self,
            .step = stepCallback,
            .cancel = cancelCallback,
            .deinit = deinitCallback,
        };
    }

    fn stepCallback(context: *anyopaque, allocator: Allocator, max_files: usize) anyerror!SearchStep {
        const self: *TextSearchJob = @ptrCast(@alignCast(context));
        return self.step(allocator, max_files);
    }

    fn cancelCallback(context: *anyopaque) void {
        const self: *TextSearchJob = @ptrCast(@alignCast(context));
        self.cancel();
    }

    fn deinitCallback(context: *anyopaque) void {
        const self: *TextSearchJob = @ptrCast(@alignCast(context));
        self.deinit();
    }

    fn deinit(self: *TextSearchJob) void {
        const emitted = @min(self.open_index, self.open_results.len);
        for (self.open_results[emitted..]) |*result| result.deinit();
        if (self.open_results.len > 0) self.allocator.free(self.open_results);
        if (self.worker) |worker| worker.deinit();
        self.include_list.deinit();
        self.exclude_list.deinit();
        if (self.exclude_expression) |*expression| expression.deinit();
        self.search_data.regex.deinit();
        if (self.word_classifier) |*classifier| classifier.deinit();
        freeMapKeys(self.allocator, &self.open_paths);
        freeMapKeys(self.allocator, &self.seen_paths);
        self.open_paths.deinit();
        self.seen_paths.deinit();
        self.allocator.destroy(self);
    }

    fn cancel(self: *TextSearchJob) void {
        self.cancelled = true;
        if (self.worker) |worker| worker.cancel();
    }

    fn step(self: *TextSearchJob, allocator: Allocator, max_files: usize) !SearchStep {
        var results = std.array_list.Managed(SearchFileResult).init(allocator);
        errdefer {
            for (results.items) |*result| result.deinit();
            results.deinit();
        }
        var messages = std.array_list.Managed(SearchMessage).init(allocator);
        errdefer {
            for (messages.items) |message| allocator.free(message.text);
            messages.deinit();
        }

        if (self.cancelled) {
            self.done = true;
            return .{
                .results = try results.toOwnedSlice(),
                .done = true,
                .limit_hit = self.limit_hit,
                .messages = try messages.toOwnedSlice(),
            };
        }

        // Open editor results are already filtered and limited.
        while (self.open_index < self.open_results.len and results.items.len < max_files) {
            try results.append(self.open_results[self.open_index]);
            self.open_index += 1;
        }

        if (self.worker) |worker| {
            _ = worker.waitForWork(1);
            const items = try worker.takeBatch(allocator, max_files -| results.items.len);
            defer allocator.free(items);
            for (items) |item_value| {
                var item = item_value;
                defer item.deinit();
                if (self.cancelled or self.limit_hit) continue;
                _ = try self.acceptItem(&item, &results);
                if (self.limit_hit) worker.cancel();
            }
            if (self.limit_hit) self.done = true;
            if (!self.done and worker.isFinished() and !worker.hasQueued()) {
                self.done = true;
            }
            if (self.done or worker.isFinished()) {
                const worker_messages = try worker.takeMessages(allocator);
                defer self.allocator.free(worker_messages);
                for (worker_messages) |message| try messages.append(message);
            }
        } else if (self.open_index >= self.open_results.len) {
            self.done = true;
        }

        return .{
            .results = try results.toOwnedSlice(),
            .done = self.done,
            .limit_hit = self.limit_hit,
            .messages = try messages.toOwnedSlice(),
        };
    }

    fn acceptItem(
        self: *TextSearchJob,
        item: *text_worker.Item,
        results: *std.array_list.Managed(SearchFileResult),
    ) !bool {
        const folder_index = item.folder_index;
        if (folder_index >= self.query.folder_paths.len) return false;
        const root = self.query.folder_paths[folder_index];
        const relative = item.file.path;
        const basename = baseName(relative);
        const resource = try std.fs.path.join(self.allocator, &.{ root, relative });
        defer self.allocator.free(resource);

        const resource_key = try openPathKey(self.allocator, resource);
        defer self.allocator.free(resource_key);
        if (self.open_paths.contains(resource_key)) return false;
        if (item.exception_run) {
            if (self.seen_paths.contains(resource)) return false;
            var excepted = self.excludeListExcepted(relative);
            if (self.exclude_expression) |*expression| {
                if (self.isExceptedPath(expression, root, relative)) excepted = true;
            }
            if (!excepted) return false;
            if (!self.matchesInclude(relative)) return false;
            if (self.isNestedRoot(folder_index, relative)) return false;
            const key = try self.allocator.dupe(u8, resource);
            errdefer self.allocator.free(key);
            try self.seen_paths.put(key, {});
        } else {
            if (!self.matchesFilter(root, relative)) return false;
            if (self.exclude_expression) |*expression| {
                if (expression.isExcepted(relative, basename)) {
                    if (!self.seen_paths.contains(resource)) {
                        const key = try self.allocator.dupe(u8, resource);
                        errdefer self.allocator.free(key);
                        try self.seen_paths.put(key, {});
                    }
                }
            }
        }

        const range_count = countRanges(item.file.matches);
        if (range_count == 0) return false;
        const remaining = if (self.query.max_results > self.total_matches)
            self.query.max_results - self.total_matches
        else
            0;
        if (remaining == 0) {
            self.limit_hit = true;
            return false;
        }

        var matches = item.file.matches;
        const contexts = item.file.contexts;
        const relative_path = item.file.path;
        item.file.matches = &.{};
        item.file.contexts = &.{};
        item.file.path = &.{};
        self.allocator.free(relative_path);

        if (range_count > remaining) {
            const trimmed = try self.trimMatches(matches, remaining);
            self.allocator.free(matches);
            matches = trimmed;
            self.limit_hit = true;
        }
        self.total_matches += @min(range_count, remaining);

        const resource_copy = try self.allocator.dupe(u8, resource);
        errdefer self.allocator.free(resource_copy);
        errdefer {
            for (matches) |*match| match.deinit();
            self.allocator.free(matches);
            for (contexts) |*context| context.deinit(self.allocator);
            self.allocator.free(contexts);
        }
        try results.append(.{
            .allocator = self.allocator,
            .resource = resource_copy,
            .results = matches,
            .contexts = contexts,
        });
        return true;
    }

    fn trimMatches(self: *TextSearchJob, matches: []TextSearchMatch, allowed: usize) ![]TextSearchMatch {
        var kept = std.array_list.Managed(TextSearchMatch).init(self.allocator);
        errdefer {
            for (kept.items) |*match| match.deinit();
            kept.deinit();
        }
        var remaining = allowed;
        for (matches, 0..) |match, index| {
            if (remaining == 0) {
                var mutable = match;
                mutable.deinit();
                continue;
            }
            if (match.range_locations.len <= remaining) {
                try kept.append(match);
                remaining -= match.range_locations.len;
                continue;
            }
            const preview = try self.allocator.dupe(u8, match.preview_text);
            errdefer self.allocator.free(preview);
            const ranges = try self.allocator.dupe(RangeLocation, match.range_locations[0..remaining]);
            errdefer self.allocator.free(ranges);
            var original = match;
            original.deinit();
            try kept.append(.{
                .allocator = self.allocator,
                .preview_text = preview,
                .range_locations = ranges,
            });
            remaining = 0;
            _ = index;
        }
        return kept.toOwnedSlice();
    }

    fn countRanges(matches: []const TextSearchMatch) usize {
        var count: usize = 0;
        for (matches) |match| count += match.range_locations.len;
        return count;
    }

    fn matchesInclude(self: *TextSearchJob, relative: []const u8) bool {
        if (!self.include_list.isEmpty()) {
            if (!self.include_list.hasPositiveRule() or !self.include_list.matches(relative)) return false;
        }
        return true;
    }

    fn matchesFilter(self: *TextSearchJob, root: []const u8, relative: []const u8) bool {
        if (!self.include_list.isEmpty()) {
            if (!self.include_list.hasPositiveRule() or !self.include_list.matches(relative)) return false;
        }
        if (!self.exclude_list.isEmpty() and self.excludeListMatches(relative)) return false;
        if (self.exclude_expression) |*expression| {
            self.sibling_root = root;
            defer self.sibling_root = "";
            if (self.excludedByConfig(expression, relative)) return false;
        }
        return true;
    }

    fn excludedByConfig(self: *TextSearchJob, expression: *ParsedExcludeExpression, relative: []const u8) bool {
        var current = relative;
        while (true) {
            if (expression.matchesWithSiblings(current, baseName(current), .{
                .context = self,
                .callback = hasSiblingCallback,
            })) return true;
            current = parentPath(current) orelse return false;
        }
    }

    fn isExceptedPath(self: *TextSearchJob, expression: *ParsedExcludeExpression, root: []const u8, relative: []const u8) bool {
        self.sibling_root = root;
        defer self.sibling_root = "";
        var current = relative;
        while (true) {
            if (expression.isExcepted(current, baseName(current))) return true;
            current = parentPath(current) orelse return false;
        }
    }

    fn excludeListExcepted(self: *TextSearchJob, relative: []const u8) bool {
        var current = relative;
        while (true) {
            if (self.exclude_list.matchesNegated(current)) return true;
            current = parentPath(current) orelse return false;
        }
    }

    fn excludeListMatches(self: *TextSearchJob, relative: []const u8) bool {
        if (self.exclude_list.matchesNegated(relative)) return false;
        var current = relative;
        while (true) {
            if (self.exclude_list.matches(current)) return true;
            current = parentPath(current) orelse return false;
        }
    }

    fn hasSiblingCallback(context: *anyopaque, clause: []const u8) bool {
        const self: *TextSearchJob = @ptrCast(@alignCast(context));
        if (self.sibling_root.len == 0) return false;
        if (std.fs.path.dirname(clause) != null) {
            const path = std.fs.path.join(self.allocator, &.{ self.sibling_root, clause }) catch return false;
            defer self.allocator.free(path);
            Io.Dir.cwd().access(self.io, path, .{}) catch return false;
            return true;
        }
        var dir = Io.Dir.cwd().openDir(self.io, self.sibling_root, .{ .iterate = true }) catch return false;
        defer dir.close(self.io);
        var iterator = dir.iterate();
        while (iterator.next(self.io) catch null) |child| {
            if (std.mem.eql(u8, child.name, clause)) return true;
        }
        return false;
    }

    fn isNestedRoot(self: *TextSearchJob, folder_index: usize, relative: []const u8) bool {
        const root = self.query.folder_paths[folder_index];
        for (self.query.folder_paths, 0..) |other, other_index| {
            if (other_index == folder_index) continue;
            if (!pathIsEqualOrParent(other, root)) continue;
            var nested = std.mem.trimStart(u8, other[root.len..], "/\\");
            if (nested.len == 0) continue;
            if (std.mem.indexOfScalar(u8, nested, '\\') != null) {
                const normalized = self.allocator.dupe(u8, nested) catch continue;
                defer self.allocator.free(normalized);
                for (normalized) |*ch| {
                    if (ch.* == '\\') ch.* = '/';
                }
                nested = normalized;
                if (pathIsEqualOrParent(relative, nested)) return true;
                continue;
            }
            if (pathIsEqualOrParent(relative, nested)) return true;
        }
        return false;
    }

    fn searchOpenBuffers(self: *TextSearchJob) !void {
        const open_files = self.collectOpenPaths() catch return;
        defer if (self.provider.free_paths) |free_paths| {
            free_paths(self.provider.context, self.allocator, open_files);
        } else {
            for (open_files) |path| self.allocator.free(path);
            self.allocator.free(open_files);
        };

        var results = std.array_list.Managed(SearchFileResult).init(self.allocator);
        errdefer {
            for (results.items) |*result| result.deinit();
            results.deinit();
        }
        for (open_files) |path| {
            if (self.total_matches >= self.query.max_results) {
                self.limit_hit = true;
                break;
            }
            const open_key = try openPathKey(self.allocator, path);
            defer self.allocator.free(open_key);
            if (self.open_paths.contains(open_key)) continue;
            const read = self.provider.read orelse continue;
            const content = (read(self.provider.context, self.allocator, path) catch null) orelse continue;
            defer self.allocator.free(content);
            const key = try openPathKey(self.allocator, path);
            errdefer self.allocator.free(key);
            try self.open_paths.put(key, {});
            const root = self.workspaceFolderFor(path) orelse std.fs.path.dirname(path) orelse path;
            const relative = relativePathFor(root, path);
            if (!self.matchesFilter(root, relative)) continue;
            if (try self.searchContent(path, root, relative, content)) |file| {
                try results.append(file);
            }
        }
        self.open_results = try results.toOwnedSlice();
    }

    fn collectOpenPaths(self: *TextSearchJob) ![][]u8 {
        if (self.provider.open_files) |open_files| {
            return open_files(self.provider.context, self.allocator);
        }
        if (self.provider.extra_files) |extra_files| {
            return extra_files(self.provider.context, self.allocator);
        }
        return self.allocator.alloc([]u8, 0);
    }

    fn workspaceFolderFor(self: *TextSearchJob, path: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        for (self.query.folder_paths) |folder| {
            if (!pathIsEqualOrParent(path, folder)) continue;
            if (best == null or folder.len > best.?.len) best = folder;
        }
        return best;
    }

    fn searchContent(
        self: *TextSearchJob,
        path: []const u8,
        root: []const u8,
        relative: []const u8,
        content: []const u8,
    ) !?SearchFileResult {
        _ = root;
        if (content.len > (self.query.max_file_size orelse MAX_FILE_SIZE)) return null;
        if (hasNulByte(content)) return null;
        const text = try normalizeContent(self.allocator, content);
        defer self.allocator.free(text);
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;

        const line_starts = try collectLineStarts(self.allocator, text);
        defer self.allocator.free(line_starts);

        var results = std.array_list.Managed(TextSearchMatch).init(self.allocator);
        errdefer {
            for (results.items) |*match| match.deinit();
            results.deinit();
        }
        var contexts = std.array_list.Managed(TextSearchContext).init(self.allocator);
        errdefer {
            for (contexts.items) |*context| context.deinit(self.allocator);
            contexts.deinit();
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
                    try self.flushLine(text, line_starts, current_line.?, &ranges, &results);
                    ranges.clearRetainingCapacity();
                    current_line = null;
                }
                const start_line = lineStart(line_starts, start_pos.line);
                const end_line_end = lineEnd(text, line_starts, end_pos.line);
                if (end_line_end >= start_line) {
                    const source = SearchRange.init(
                        start_pos.line,
                        start - start_line,
                        end_pos.line,
                        end - lineStart(line_starts, end_pos.line),
                    );
                    const one = [_]SearchRange{source};
                    try results.append(try TextSearchMatch.init(self.allocator, text[start_line..end_line_end], &one, self.query.preview));
                    self.total_matches += 1;
                }
            } else {
                if (current_line == null or current_line.? != start_pos.line) {
                    if (current_line != null) {
                        try self.flushLine(text, line_starts, current_line.?, &ranges, &results);
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
        if (current_line != null) try self.flushLine(text, line_starts, current_line.?, &ranges, &results);

        if (self.query.surrounding_context > 0 and results.items.len > 0) {
            try self.appendContexts(text, line_starts, results.items, &contexts);
        }

        if (results.items.len == 0) {
            results.deinit();
            contexts.deinit();
            return null;
        }
        const resource = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(resource);
        _ = relative;
        return .{
            .allocator = self.allocator,
            .resource = resource,
            .results = try results.toOwnedSlice(),
            .contexts = try contexts.toOwnedSlice(),
        };
    }

    fn flushLine(
        self: *TextSearchJob,
        text: []const u8,
        line_starts: []const usize,
        line_index: usize,
        ranges: *std.array_list.Managed(SearchRange),
        results: *std.array_list.Managed(TextSearchMatch),
    ) !void {
        if (ranges.items.len == 0) return;
        const start = lineStart(line_starts, line_index);
        const end = lineEnd(text, line_starts, line_index);
        try results.append(try TextSearchMatch.init(self.allocator, text[start..end], ranges.items, self.query.preview));
    }

    fn appendContexts(
        self: *TextSearchJob,
        text: []const u8,
        line_starts: []const usize,
        matches: []const TextSearchMatch,
        contexts: *std.array_list.Managed(TextSearchContext),
    ) !void {
        var lines = std.AutoHashMap(usize, void).init(self.allocator);
        defer lines.deinit();
        const count = self.query.surrounding_context;
        for (matches) |match| {
            for (match.range_locations) |location| {
                const start_line = location.source.start_line_number;
                const end_line = location.source.end_line_number;
                var line = start_line -| count;
                while (line <= end_line + count) : (line += 1) {
                    if (line >= line_starts.len) break;
                    if (line >= start_line and line <= end_line) continue;
                    if (lines.contains(line)) continue;
                    try lines.put(line, {});
                    const start = lineStart(line_starts, line);
                    const end = lineEnd(text, line_starts, line);
                    try contexts.append(.{
                        .text = try self.allocator.dupe(u8, text[start..end]),
                        .line_number = line + 1,
                    });
                }
            }
        }
        std.mem.sort(TextSearchContext, contexts.items, {}, struct {
            fn lessThan(_: void, a: TextSearchContext, b: TextSearchContext) bool {
                return a.line_number < b.line_number;
            }
        }.lessThan);
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
    return starts.toOwnedSlice();
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
    return out.toOwnedSlice();
}

fn hasNulByte(content: []const u8) bool {
    const limit = @min(content.len, 8192);
    return std.mem.indexOfScalar(u8, content[0..limit], 0) != null;
}

fn parentPath(path: []const u8) ?[]const u8 {
    var end = path.len;
    while (end > 0) : (end -= 1) {
        if (path[end - 1] == '/' or path[end - 1] == '\\') {
            if (end == 1) return null;
            return path[0 .. end - 1];
        }
    }
    return null;
}

fn baseName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0) : (end -= 1) {
        if (path[end - 1] == '/' or path[end - 1] == '\\') return path[end..];
    }
    return path;
}

fn relativePathFor(root: []const u8, path: []const u8) []const u8 {
    if (std.mem.eql(u8, root, path)) return baseName(path);
    if (!std.mem.startsWith(u8, path, root)) return path;
    var index = root.len;
    if (index < path.len and (path[index] == '/' or path[index] == '\\')) index += 1;
    return path[index..];
}

fn pathIsEqualOrParent(path: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, path, parent)) return true;
    if (path.len <= parent.len) return false;
    if (!std.mem.startsWith(u8, path, parent)) return false;
    return path[parent.len] == '/' or path[parent.len] == '\\';
}

/// Canonical map key for the open-buffer set. Ripgrep reports `\` separators
/// on Windows while editors keep the path spelling the caller supplied, so the
/// same file would be searched twice, and its open-buffer result plus the
/// workspace match would both surface. POSIX keeps `\` as a filename byte, so
/// only Windows rewrites separators.
fn openPathKey(allocator: Allocator, path: []const u8) ![]u8 {
    const key = try allocator.dupe(u8, path);
    if (builtin.os.tag == .windows) {
        for (key) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
    }
    return key;
}

fn freeMapKeys(allocator: Allocator, map: *std.StringHashMap(void)) void {
    var iterator = map.keyIterator();
    while (iterator.next()) |key| allocator.free(key.*);
}
