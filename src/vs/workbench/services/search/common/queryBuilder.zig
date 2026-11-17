// Port of the text-search subset of
// `src/vs/workbench/services/search/common/queryBuilder.ts`.
//
// The terminal query builder keeps the upstream decisions that affect the
// Search view: content-pattern normalization, smart case, preview options,
// max results, extra file resources and configuration excludes. Browser-only
// pieces are not ported:
// - `expandPatterns` (`./` and absolute search paths) are treated as ordinary
//   globs; the terminal search service has no search-path roots;
// - only-open-editors and changed-files queries need editor-group/SCM
//   services that the terminal does not have;
// - per-folder settings and per-folder include/exclude expressions are not
//   resolved; one workspace-level expression is applied to every root.
//
// `files.exclude` and `search.exclude` are merged through the ported
// `getExcludes` so `!` exceptions and `{ when: ... }` sibling clauses keep
// working in the search service.

const std = @import("std");
const Allocator = std.mem.Allocator;

const search = @import("search.zig");
const PatternInfo = search.PatternInfo;
const TextQuery = search.TextQuery;
const TextQueryOptions = search.TextQueryOptions;
const PreviewOptions = search.PreviewOptions;
const DEFAULT_MAX_SEARCH_RESULTS = search.DEFAULT_MAX_SEARCH_RESULTS;
const glob = @import("../../../../base/common/glob.zig");
const configuration_service = @import("../../configuration/browser/configurationService.zig");
const ConfigurationService = configuration_service.ConfigurationService;
const workspace_context = @import("../../workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;

pub const TextQueryBuilderOptions = struct {
    include_pattern: []const u8 = "",
    exclude_pattern: []const u8 = "",
    extra_files: []const []const u8 = &.{},
    max_results: ?usize = null,
    preview: ?PreviewOptions = null,
    /// Mirrors upstream `useExcludesAndIgnoreFiles`. When false, neither
    /// `files.exclude`/`search.exclude` nor ignore files are consulted.
    use_excludes_and_ignore_files: bool = true,
    is_smart_case: bool = false,
};

pub const QueryBuilder = struct {
    allocator: Allocator,
    configuration: *const ConfigurationService,
    workspace: *WorkspaceContextService,

    pub fn init(
        allocator: Allocator,
        configuration_service_value: *const ConfigurationService,
        workspace: *WorkspaceContextService,
    ) QueryBuilder {
        return .{
            .allocator = allocator,
            .configuration = configuration_service_value,
            .workspace = workspace,
        };
    }

    /// Port of `QueryBuilder.text`.
    pub fn text(
        self: *const QueryBuilder,
        content: PatternInfo,
        options: TextQueryBuilderOptions,
    ) !TextQuery {
        const allocator = self.allocator;
        const normalized = try self.getContentPattern(allocator, content, options.is_smart_case);
        defer allocator.free(normalized.pattern);

        var folder_paths = std.array_list.Managed([]const u8).init(allocator);
        defer folder_paths.deinit();
        for (self.workspace.getWorkspace().folders.items) |folder| {
            try folder_paths.append(folder.resource);
        }

        const use_excludes = options.use_excludes_and_ignore_files;
        var excludes: []glob.ExcludeEntry = &.{};
        if (use_excludes) {
            excludes = try search.getExcludes(
                allocator,
                self.configuration.getValue("files.exclude", .{}),
                self.configuration.getValue("search.exclude", .{}),
            );
        }
        defer search.freeExcludes(allocator, excludes);

        var query = try TextQuery.initWithOptions(
            allocator,
            normalized.pattern,
            folder_paths.items,
            trimPattern(options.include_pattern),
            trimPattern(options.exclude_pattern),
            options.extra_files,
            .{
                .preview = options.preview orelse .{
                    .match_lines = 1,
                    .chars_per_line = if (content.is_regex) 10000 else 1000,
                },
                .max_results = options.max_results orelse self.maxResults(),
                .use_ignore_files = use_excludes and self.configuration.getBool("search.useIgnoreFiles", true),
                .exclude_entries = excludes,
            },
        );
        errdefer query.deinit();

        query.is_regex = content.is_regex;
        query.is_word_match = content.is_word_match;
        query.is_case_sensitive = normalized.is_case_sensitive;
        return query;
    }

    fn maxResults(self: *const QueryBuilder) usize {
        const value = self.configuration.getValue("search.maxResults", .{}) orelse
            return DEFAULT_MAX_SEARCH_RESULTS;
        return switch (value.*) {
            .null => std.math.maxInt(usize),
            .integer => |inner| if (inner > 0) @intCast(inner) else DEFAULT_MAX_SEARCH_RESULTS,
            else => DEFAULT_MAX_SEARCH_RESULTS,
        };
    }

    /// Port of `QueryBuilder.getContentPattern` for the text-search subset.
    fn getContentPattern(
        self: *const QueryBuilder,
        allocator: Allocator,
        content: PatternInfo,
        is_smart_case: bool,
    ) !PatternInfo {
        _ = self;
        const pattern = if (content.is_regex)
            try normalizeRegexNewlines(allocator, content.pattern)
        else
            try allocator.dupe(u8, content.pattern);
        errdefer allocator.free(pattern);

        return .{
            .pattern = pattern,
            .is_regex = content.is_regex,
            .is_word_match = content.is_word_match,
            .is_case_sensitive = content.is_case_sensitive or
                (is_smart_case and containsUppercaseCharacter(pattern, content.is_regex)),
            .word_separators = content.word_separators,
        };
    }
};

fn trimPattern(pattern: []const u8) []const u8 {
    return std.mem.trim(u8, pattern, " \t\r\n");
}

/// Upstream rewrites literal newlines in a regex source to `\n` so a
/// multi-line content pattern stays one regex. This keeps the same behavior
/// without a JavaScript regex engine.
fn normalizeRegexNewlines(allocator: Allocator, pattern: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < pattern.len) {
        if (pattern[index] == '\r' and index + 1 < pattern.len and pattern[index + 1] == '\n') {
            try out.appendSlice("\\n");
            index += 2;
            continue;
        }
        if (pattern[index] == '\n') {
            try out.appendSlice("\\n");
            index += 1;
            continue;
        }
        try out.append(pattern[index]);
        index += 1;
    }
    return try out.toOwnedSlice();
}

/// Port of `strings.containsUppercaseCharacter`. For regex sources an escaped
/// character is ignored, so `\A` does not turn on smart case.
pub fn containsUppercaseCharacter(text: []const u8, is_regex: bool) bool {
    var escaped = false;
    for (text) |character| {
        if (is_regex) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (character == '\\') {
                escaped = true;
                continue;
            }
        }
        if (std.ascii.isUpper(character)) return true;
    }
    return false;
}

// Keep the glob import explicit through the public re-export used by the
// `excludes` local; Zig otherwise infers an anonymous type name that is not
// part of the module's public surface.
