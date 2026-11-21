// Port of `src/vs/workbench/contrib/search/browser/searchTreeModel/searchModel.ts`.
//
// Terminal adaptation: the service returns an incremental `ISearchJob` instead
// of a promise, and `poll` advances it from the app loop. The result tree and
// replacement state follow upstream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const search = @import("../../../../services/search/common/search.zig");
const TextQuery = search.TextQuery;
const ISearchJob = search.ISearchJob;
const ISearchService = search.ISearchService;
const SearchStep = search.SearchStep;
const SearchResult = @import("searchTreeCommon.zig").SearchResult;
const ReplacePattern = @import("../../../../services/search/common/replace.zig").ReplacePattern;
const Emitter = @import("../../../../../base/common/event.zig").Emitter;

pub const SearchModel = struct {
    allocator: Allocator,
    service: ISearchService,
    result: *SearchResult,
    query: ?TextQuery = null,
    current_job: ?ISearchJob = null,
    replace_string: []u8,
    replace_pattern: ?ReplacePattern = null,
    replace_active: bool = false,
    preserve_case: bool = false,
    current_limit_hit: bool = false,
    pending_message: ?@import("../../../../services/search/common/search.zig").SearchMessage = null,
    on_replace_term_changed: Emitter(void),

    pub fn init(allocator: Allocator, service: ISearchService) !*SearchModel {
        const self = try allocator.create(SearchModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .service = service,
            .result = try SearchResult.create(allocator),
            .replace_string = try allocator.dupe(u8, ""),
            .on_replace_term_changed = Emitter(void).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *SearchModel) void {
        _ = self.cancelSearch();
        if (self.query) |*query| query.deinit();
        if (self.replace_pattern) |*pattern| pattern.deinit();
        if (self.pending_message) |message| self.allocator.free(message.text);
        self.result.deinit();
        self.on_replace_term_changed.deinit();
        self.allocator.free(self.replace_string);
        self.allocator.destroy(self);
    }

    pub fn searchResult(self: *SearchModel) *SearchResult {
        return self.result;
    }

    pub fn isReplaceActive(self: *const SearchModel) bool {
        return self.replace_active;
    }

    pub fn replacePattern(self: *const SearchModel) ?*const ReplacePattern {
        if (self.replace_pattern) |*pattern| return pattern;
        return null;
    }

    pub fn replaceString(self: *const SearchModel) []const u8 {
        return self.replace_string;
    }

    pub fn setReplaceString(self: *SearchModel, value: []const u8) !void {
        const copy = try self.allocator.dupe(u8, value);
        self.allocator.free(self.replace_string);
        self.replace_string = copy;
        self.rebuildReplacePattern();
        self.on_replace_term_changed.fire({}) catch {};
    }

    pub fn setPreserveCase(self: *SearchModel, value: bool) void {
        self.preserve_case = value;
        self.on_replace_term_changed.fire({}) catch {};
    }

    fn rebuildReplacePattern(self: *SearchModel) void {
        if (self.replace_pattern) |*pattern| {
            pattern.deinit();
            self.replace_pattern = null;
        }
        const query = self.query orelse return;
        self.replace_pattern = ReplacePattern.init(
            self.allocator,
            self.replace_string,
            query.patternInfo(),
        ) catch null;
    }

    /// Takes ownership of `query`, cancels any previous search and starts a new
    /// job. Returns false when the query cannot be parsed.
    pub fn search(self: *SearchModel, query: TextQuery) !bool {
        _ = self.cancelSearch();
        self.result.setQuery(null);
        if (self.query) |*old| old.deinit();
        self.query = query;
        self.result.setQuery(&self.query.?);
        self.current_limit_hit = false;
        if (self.pending_message) |message| self.allocator.free(message.text);
        self.pending_message = null;
        self.rebuildReplacePattern();
        self.current_job = self.service.start_text_search(
            self.service.context,
            &self.query.?,
        ) catch |err| {
            // Invalid patterns are reported by the view; leave the result empty.
            if (err == error.InvalidSearchPattern) return false;
            return err;
        };
        return true;
    }

    /// Advances the current job by at most `max_files` files. Returns true when
    /// the result tree changed and the view should rebuild.
    pub fn poll(self: *SearchModel, max_files: usize) !bool {
        const job = self.current_job orelse return false;
        const step: SearchStep = try job.step(job.context, self.allocator, max_files);
        defer {
            for (step.results) |*file| file.deinit();
            self.allocator.free(step.results);
            for (step.messages) |message| self.allocator.free(message.text);
            if (step.messages.len > 0) self.allocator.free(step.messages);
        }
        if (step.results.len > 0) {
            try self.result.add(step.results, false);
        }
        var failed = false;
        for (step.messages, 0..) |message, index| {
            if (self.pending_message) |old| self.allocator.free(old.text);
            self.pending_message = null;
            if (index == 0) {
                self.pending_message = message;
            } else {
                self.allocator.free(message.text);
            }
            if (message.kind == .err) failed = true;
        }
        if (failed) {
            job.cancel(job.context);
        }
        if (step.done or failed) {
            self.current_limit_hit = step.limit_hit;
            job.deinit(job.context);
            self.current_job = null;
        }
        return step.results.len > 0 or step.done or failed;
    }

    pub fn isSearching(self: *const SearchModel) bool {
        return self.current_job != null;
    }

    pub fn limitHit(self: *const SearchModel) bool {
        return self.current_limit_hit;
    }

    /// Transfers the latest runtime message to the view.
    pub fn takeMessage(self: *SearchModel) ?@import("../../../../services/search/common/search.zig").SearchMessage {
        const message = self.pending_message;
        self.pending_message = null;
        return message;
    }

    pub fn cancelSearch(self: *SearchModel) bool {
        if (self.current_job) |job| {
            job.cancel(job.context);
            job.deinit(job.context);
            self.current_job = null;
            return true;
        }
        return false;
    }

    pub fn clear(self: *SearchModel) void {
        _ = self.cancelSearch();
        if (self.pending_message) |message| self.allocator.free(message.text);
        self.pending_message = null;
        self.result.clear();
        if (self.query) |*query| {
            self.result.setQuery(null);
            query.deinit();
            self.query = null;
        }
        if (self.replace_pattern) |*pattern| {
            pattern.deinit();
            self.replace_pattern = null;
        }
    }
};
