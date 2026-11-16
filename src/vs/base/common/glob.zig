// Port of `src/vs/base/common/glob.ts` (subset) for terminal workspace search
// and `.gitignore` handling.
//
// Upstream compiles a glob pattern to a JavaScript `RegExp` source string
// (`parseRegExp`) and short-circuits the common shapes (`**/*.ext`, `**/name`,
// `{**/a,**/b}`) with `endsWith`/basename/equality checks. The terminal has no
// JavaScript `RegExp`, so this port keeps upstream's pattern language and
// options but replaces the generated regular expression with an equivalent
// segment matcher: the pattern is split into path segments and matched segment
// by segment, with `**` consuming zero or more segments. Supporting parts:
//
// * `*` matches zero or more characters inside one path segment, `?` one
//   character inside one segment, `**` any number of segments.
// * `{a,b}` groups alternatives (no nesting, like upstream).
// * `[abc]`, `[a-z]`, `[!0-9]` character classes; `]` is literal when it is the
//   first character of the class.
// * `trimForExclusions` drops a trailing `/**` so an exclusion pattern prunes
//   the folder itself during a traversal, like upstream.
// * `ignoreCase` folds ASCII case while matching.
//
// Not ported: sibling clauses (`{ when: ... }`), the `Promise`-returning
// `hasSibling` matcher, the parsed-pattern metadata
// (`allBasenames`/`allPaths`) and the LRU cache of parsed patterns.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Simplify patterns for use as exclusion filters during a tree traversal,
    /// so that `foo/**` excludes the folder `foo` itself. Upstream calls this
    /// `trimForExclusions`.
    trim_for_exclusions: bool = false,
    ignore_case: bool = false,
};

/// Mirrors upstream `IRelativePattern`: `pattern` is matched relative to
/// `base`, and `base` must be equal to or a parent of the candidate path.
pub const RelativePattern = struct {
    base: []const u8,
    pattern: []const u8,
};

/// Either a plain glob string or a relative pattern.
pub const Source = union(enum) {
    string: []const u8,
    relative: RelativePattern,
};

/// One brace-expanded glob pattern split into path segments.
pub const Pattern = struct {
    segments: []const []const u8,
    ignore_case: bool,
    /// When set, the pattern only matches inside this base path and the base is
    /// stripped before segment matching, like upstream `wrapRelativePattern`.
    base: ?[]const u8 = null,

    pub fn matches(self: Pattern, path: []const u8) bool {
        var candidate = path;
        if (self.base) |base| {
            candidate = stripBase(path, base, self.ignore_case) orelse return false;
        }
        return matchSegments(self.segments, 0, candidate, 0, self.ignore_case);
    }
};

fn stripBase(path: []const u8, base: []const u8, ignore_case: bool) ?[]const u8 {
    if (path.len < base.len) return null;
    if (ignore_case) {
        if (!std.ascii.startsWithIgnoreCase(path, base)) return null;
    } else {
        if (!std.mem.startsWith(u8, path, base)) return null;
    }
    if (path.len == base.len) return path[path.len..];
    if (isSeparator(base[base.len - 1])) return path[base.len..];
    if (!isSeparator(path[base.len])) return null;
    return path[base.len + 1 ..];
}

fn isSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

/// A parsed glob expression, the equivalent of upstream's `ParsedExpression`
/// for a list of patterns that all have to match: `matches` is true when any
/// pattern matches. The slices are owned by the arena passed to `init`.
pub const Expression = struct {
    patterns: []const Pattern,

    pub const empty = Expression{ .patterns = &.{} };

    pub fn init(arena: Allocator, patterns: []const []const u8, options: Options) !Expression {
        var list = std.array_list.Managed(Pattern).init(arena);
        for (patterns) |pattern| {
            try appendExpanded(arena, &list, pattern, null, options);
        }
        return .{ .patterns = try list.toOwnedSlice() };
    }

    /// Compiles plain and relative patterns. Relative bases are copied into
    /// `arena`, so the caller does not need to keep the sources alive.
    pub fn initSources(arena: Allocator, sources: []const Source, options: Options) !Expression {
        var list = std.array_list.Managed(Pattern).init(arena);
        for (sources) |source| {
            switch (source) {
                .string => |pattern| try appendExpanded(arena, &list, pattern, null, options),
                .relative => |relative| {
                    const base = try arena.dupe(u8, relative.base);
                    try appendExpanded(arena, &list, relative.pattern, base, options);
                },
            }
        }
        return .{ .patterns = try list.toOwnedSlice() };
    }

    pub fn isEmpty(self: Expression) bool {
        return self.patterns.len == 0;
    }

    pub fn matches(self: Expression, path: []const u8) bool {
        for (self.patterns) |pattern| {
            if (pattern.matches(path)) return true;
        }
        return false;
    }
};

/// A comma-separated glob expression as used by the search include/exclude
/// inputs: each piece may start with `!` to re-include a path, and evaluation
/// is last-rule-wins, matching upstream's expression semantics.
/// One entry of an `IExpression`-shaped exclude object. The order is kept so
/// the caller can build the same expression that the configuration object
/// describes. `enabled == false` mirrors upstream `value === false`.
pub const ExcludeEntry = struct {
    pattern: []const u8,
    enabled: bool = true,
};

/// Mirrors upstream `isExcludeException`.
pub fn isExcludeException(pattern: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, pattern, " \t\r\n");
    return trimmed.len > 0 and trimmed[0] == '!';
}

/// Mirrors upstream `escapeExcludeException`: rewrites a leading `!` as `{!}`
/// so the pattern matches a literal `!` instead of being an exception.
pub fn escapeExcludeException(allocator: Allocator, pattern: []const u8) ![]u8 {
    const trimmed = std.mem.trimStart(u8, pattern, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '!') {
        return std.fmt.allocPrint(allocator, "{{!}}{s}", .{trimmed[1..]});
    }
    return allocator.dupe(u8, pattern);
}

/// Mirrors upstream `getExcludeExceptions`: enabled, non-empty, relative
/// `!`-prefixed patterns, without the prefix and without a trailing slash.
/// The returned slice and each item are owned by `allocator`.
pub fn getExcludeExceptions(allocator: Allocator, entries: []const ExcludeEntry) ![][]const u8 {
    var list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit();
    }
    for (entries) |entry| {
        if (!entry.enabled or !isExcludeException(entry.pattern)) continue;
        const raw = std.mem.trim(u8, entry.pattern, " \t\r\n");
        var pattern = std.mem.trim(u8, raw[1..], " \t\r\n");
        pattern = std.mem.trimEnd(u8, pattern, "/\\");
        if (pattern.len == 0 or isAbsolutePattern(pattern)) continue;
        try list.append(try allocator.dupe(u8, pattern));
    }
    return list.toOwnedSlice();
}

fn isAbsolutePattern(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    if (isSeparator(pattern[0])) return true;
    return pattern.len >= 2 and std.ascii.isAlphabetic(pattern[0]) and pattern[1] == ':';
}

fn isVersionControlFolder(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".svn") or
        std.mem.eql(u8, name, ".hg") or
        std.mem.eql(u8, name, ".jj");
}

fn patternNamesFolder(patterns: []const Pattern, folder: []const u8) bool {
    for (patterns) |pattern| {
        for (pattern.segments) |segment| {
            if (std.mem.eql(u8, segment, folder)) return true;
        }
    }
    return false;
}

fn isInSkippedFolder(path: []const u8, skipped: []const []const u8) bool {
    var index: usize = 0;
    while (index < path.len) {
        while (index < path.len and isSeparator(path[index])) index += 1;
        if (index >= path.len) break;
        const end = segmentEnd(path, index);
        for (skipped) |folder| {
            if (std.mem.eql(u8, path[index..end], folder)) return true;
        }
        index = end;
    }
    return false;
}

/// A parsed `files.exclude`-style expression with upstream's `!` exception
/// semantics. The arena owns the patterns, exception strings and skipped-folder
/// list.
pub const ParsedExcludeExpression = struct {
    arena: std.heap.ArenaAllocator,
    matches_exclude: Expression,
    exception_expression: Expression = Expression.empty,
    exception_patterns: []const Pattern = &.{},
    exceptions: []const []const u8 = &.{},
    skipped_folders: []const []const u8 = &.{},
    has_exceptions: bool = false,

    pub fn init(
        allocator: Allocator,
        entries: []const ExcludeEntry,
        options: Options,
    ) !ParsedExcludeExpression {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        var exclude_patterns = std.array_list.Managed([]const u8).init(arena_allocator);
        for (entries) |entry| {
            if (!entry.enabled) continue;
            const pattern = std.mem.trim(u8, entry.pattern, " \t\r\n");
            if (pattern.len == 0 or isExcludeException(pattern)) continue;
            try exclude_patterns.append(try arena_allocator.dupe(u8, pattern));
        }
        const matches_exclude = try Expression.init(arena_allocator, exclude_patterns.items, options);
        const exceptions = try getExcludeExceptions(arena_allocator, entries);
        if (exceptions.len == 0) {
            return .{
                .arena = arena,
                .matches_exclude = matches_exclude,
            };
        }

        const exception_patterns_expression = try Expression.init(arena_allocator, exceptions, .{
            .ignore_case = options.ignore_case,
            .trim_for_exclusions = false,
        });

        var exception_expression_patterns = std.array_list.Managed([]const u8).init(arena_allocator);
        for (exceptions) |exception| {
            try exception_expression_patterns.append(exception);
            try exception_expression_patterns.append(
                try std.fmt.allocPrint(arena_allocator, "{s}/**", .{exception}),
            );
        }
        const exception_expression = try Expression.init(arena_allocator, exception_expression_patterns.items, .{
            .ignore_case = options.ignore_case,
            .trim_for_exclusions = false,
        });

        var skipped_folders = std.array_list.Managed([]const u8).init(arena_allocator);
        for ([_][]const u8{ ".git", ".svn", ".hg", ".jj" }) |folder| {
            if (!patternNamesFolder(exception_patterns_expression.patterns, folder)) {
                try skipped_folders.append(folder);
            }
        }

        return .{
            .arena = arena,
            .matches_exclude = matches_exclude,
            .exception_expression = exception_expression,
            .exception_patterns = exception_patterns_expression.patterns,
            .exceptions = exceptions,
            .skipped_folders = skipped_folders.items,
            .has_exceptions = true,
        };
    }

    pub fn deinit(self: *ParsedExcludeExpression) void {
        self.arena.deinit();
    }

    /// Matches the exclude patterns only, ignoring exceptions.
    pub fn matchesExclude(self: *const ParsedExcludeExpression, path: []const u8, basename: ?[]const u8) bool {
        _ = basename;
        return self.matches_exclude.matches(path);
    }

    /// Whether the path, or one of its parents, is carved out by an exception.
    pub fn isExcepted(self: *const ParsedExcludeExpression, path: []const u8, basename: ?[]const u8) bool {
        _ = basename;
        if (!self.has_exceptions) return false;
        if (!self.exception_expression.matches(path)) return false;
        return !isInSkippedFolder(path, self.skipped_folders);
    }

    /// Matches like upstream `parseExcludeExpression(...).matches`: a path is
    /// excluded only when it matches an exclude pattern and is not excepted.
    pub fn matches(self: *const ParsedExcludeExpression, path: []const u8, basename: ?[]const u8) bool {
        if (!self.matchesExclude(path, basename)) return false;
        return !self.isExcepted(path, basename);
    }

    /// Whether an exception could match a path beneath `folder_path`.
    pub fn couldExceptionMatchBeneath(self: *const ParsedExcludeExpression, folder_path: []const u8) bool {
        if (!self.has_exceptions) return false;
        if (isInSkippedFolder(folder_path, self.skipped_folders)) return false;
        for (self.exception_patterns) |pattern| {
            if (couldMatchBeneathPattern(pattern, folder_path)) return true;
        }
        return false;
    }
};

/// Convenience alias matching the upstream function name.
pub fn parseExcludeExpression(
    allocator: Allocator,
    entries: []const ExcludeEntry,
    options: Options,
) !ParsedExcludeExpression {
    return ParsedExcludeExpression.init(allocator, entries, options);
}

fn segmentEnd(path: []const u8, start: usize) usize {
    var index = start;
    while (index < path.len and !isSeparator(path[index])) index += 1;
    return index;
}

/// Whether the expanded pattern could match a path below `folder_path`.
fn couldMatchBeneathPattern(pattern: Pattern, folder_path: []const u8) bool {
    return couldMatchBeneathSegments(pattern.segments, 0, folder_path, 0, pattern.ignore_case);
}

fn couldMatchBeneathSegments(
    segments: []const []const u8,
    matcher_index: usize,
    path: []const u8,
    start: usize,
    ignore_case: bool,
) bool {
    var index = start;
    while (index < path.len and isSeparator(path[index])) index += 1;
    if (index >= path.len) return true; // the folder is exhausted; a pattern may still match below
    if (matcher_index >= segments.len) return false;

    const segment = segments[matcher_index];
    if (std.mem.eql(u8, segment, "**")) {
        if (couldMatchBeneathSegments(segments, matcher_index + 1, path, index, ignore_case)) return true;
        const end = segmentEnd(path, index);
        return couldMatchBeneathSegments(segments, matcher_index, path, end + 1, ignore_case);
    }

    const end = segmentEnd(path, index);
    if (!segmentMatches(segment, path[index..end], ignore_case)) return false;
    return couldMatchBeneathSegments(segments, matcher_index + 1, path, end + 1, ignore_case);
}

/// Optional callbacks used by `evaluateExcludeTreeEntry`, mirroring the
/// upstream `hasSibling` and `isHidden` entry hooks.
pub const IsHidden = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque) bool,
};

pub const HasSibling = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, name: []const u8) bool,
};

pub const ExcludeTreeEntry = struct {
    path: []const u8,
    basename: ?[]const u8 = null,
    is_directory: bool,
    is_parent_excluded: bool,
    is_hidden: ?IsHidden = null,
    has_sibling: ?HasSibling = null,
};

pub const ExcludeTreeResult = struct {
    is_excluded: bool,
    is_visited: bool,
};

/// Mirrors upstream `evaluateExcludeTreeEntry`. An excluded folder is still
/// visited when an exception could match beneath it, so the walker can find
/// the exception.
pub fn evaluateExcludeTreeEntry(
    parsed: *const ParsedExcludeExpression,
    entry: ExcludeTreeEntry,
) ExcludeTreeResult {
    _ = entry.has_sibling;
    const hidden = if (entry.is_hidden) |hook| hook.callback(hook.context) else false;
    const matched = entry.is_parent_excluded or
        parsed.matchesExclude(entry.path, entry.basename) or hidden;
    const is_excluded = matched and !parsed.isExcepted(entry.path, entry.basename);
    return .{
        .is_excluded = is_excluded,
        .is_visited = !is_excluded or
            (entry.is_directory and parsed.couldExceptionMatchBeneath(entry.path)),
    };
}

pub const GlobList = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    rules: std.array_list.Managed(Rule),

    pub const Rule = struct {
        patterns: []const Pattern,
        negated: bool,
    };

    pub fn init(allocator: Allocator, expression: []const u8) !GlobList {
        var self = GlobList{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .rules = std.array_list.Managed(Rule).init(allocator),
        };
        errdefer self.deinit();

        const arena = self.arena.allocator();
        var start: usize = 0;
        var depth: usize = 0;
        var in_brackets = false;
        var index: usize = 0;
        while (index <= expression.len) : (index += 1) {
            const at_end = index == expression.len;
            if (!at_end) {
                const ch = expression[index];
                if (ch == '[') in_brackets = true;
                if (ch == ']') in_brackets = false;
                if (!in_brackets) {
                    if (ch == '{') depth += 1;
                    if (ch == '}' and depth > 0) depth -= 1;
                }
                if (ch != ',' or depth != 0 or in_brackets) continue;
            }
            var piece = std.mem.trim(u8, expression[start..index], " \t\r\n");
            start = index + 1;
            if (piece.len == 0) continue;
            var negated = false;
            if (piece[0] == '!') {
                negated = true;
                piece = piece[1..];
            }
            piece = normalizePattern(piece);
            if (piece.len == 0) continue;

            // A pattern without a slash matches the basename at any depth, like
            // the search process does; a trailing slash means "everything below
            // the folder".
            const written = if (std.mem.indexOfScalar(u8, piece, '/') == null)
                try std.fmt.allocPrint(arena, "**/{s}", .{piece})
            else if (piece[piece.len - 1] == '/')
                try std.fmt.allocPrint(arena, "{s}**", .{piece})
            else
                try arena.dupe(u8, piece);

            var patterns = std.array_list.Managed(Pattern).init(arena);
            try appendExpanded(arena, &patterns, written, null, .{});
            try self.rules.append(.{
                .patterns = try patterns.toOwnedSlice(),
                .negated = negated,
            });
        }
        return self;
    }

    pub fn deinit(self: *GlobList) void {
        self.rules.deinit();
        self.arena.deinit();
    }

    pub fn isEmpty(self: *const GlobList) bool {
        return self.rules.items.len == 0;
    }

    pub fn hasPositiveRule(self: *const GlobList) bool {
        for (self.rules.items) |rule| {
            if (!rule.negated) return true;
        }
        return false;
    }

    /// Returns whether `relative_path` matches the expression. An empty
    /// expression matches nothing.
    pub fn matches(self: *const GlobList, relative_path: []const u8) bool {
        if (self.rules.items.len == 0) return false;
        const path = normalizePath(relative_path);
        var result = false;
        for (self.rules.items) |rule| {
            for (rule.patterns) |pattern| {
                if (pattern.matches(path)) {
                    result = !rule.negated;
                    break;
                }
            }
        }
        return result;
    }
};

fn normalizePattern(pattern: []const u8) []const u8 {
    var value = pattern;
    while (std.mem.startsWith(u8, value, "./")) value = value[2..];
    if (value.len > 0 and value[0] == '/') value = value[1..];
    return value;
}

fn normalizePath(path: []const u8) []const u8 {
    var value = path;
    while (std.mem.startsWith(u8, value, "./")) value = value[2..];
    if (value.len > 0 and value[0] == '/') value = value[1..];
    return value;
}

const Brace = struct { open: usize, close: usize };

/// Finds the first brace group outside character classes. Brace groups do not
/// nest, matching upstream's `expandBraces`.
fn findBrace(pattern: []const u8) ?Brace {
    var index: usize = 0;
    var in_brackets = false;
    while (index < pattern.len) : (index += 1) {
        const ch = pattern[index];
        if (in_brackets) {
            if (ch == ']') in_brackets = false;
            continue;
        }
        if (ch == '[') {
            in_brackets = true;
            continue;
        }
        if (ch != '{') continue;

        var close = index + 1;
        var brackets = false;
        while (close < pattern.len) : (close += 1) {
            const inner = pattern[close];
            if (brackets) {
                if (inner == ']') brackets = false;
                continue;
            }
            if (inner == '[') {
                brackets = true;
                continue;
            }
            if (inner == '}') return .{ .open = index, .close = close };
        }
        return null;
    }
    return null;
}

fn appendExpanded(
    arena: Allocator,
    list: *std.array_list.Managed(Pattern),
    raw: []const u8,
    base: ?[]const u8,
    options: Options,
) !void {
    var pattern = std.mem.trim(u8, raw, " \t\r\n");
    if (options.trim_for_exclusions and std.mem.endsWith(u8, pattern, "/**")) {
        // Upstream drops the trailing `**`; the remaining trailing slash is
        // dropped when the pattern is split into segments.
        pattern = pattern[0 .. pattern.len - 2];
    }
    if (pattern.len == 0) return;

    if (findBrace(pattern)) |brace| {
        var alternatives = std.mem.splitScalar(u8, pattern[brace.open + 1 .. brace.close], ',');
        while (alternatives.next()) |alternative| {
            const combined = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
                pattern[0..brace.open],
                alternative,
                pattern[brace.close + 1 ..],
            });
            try appendExpanded(arena, list, combined, base, options);
        }
        return;
    }

    const owned = try normalizePatternSeparators(arena, pattern);
    try list.append(.{
        .segments = try splitSegments(arena, owned),
        .ignore_case = options.ignore_case,
        .base = base,
    });
}

/// Glob matching works on `/` even when the target path uses `\`. Upstream
/// handles both separators in its glob implementation; this port normalizes
/// patterns once and treats both separators while splitting paths.
fn normalizePatternSeparators(arena: Allocator, pattern: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, pattern, '\\') == null) {
        return try arena.dupe(u8, pattern);
    }
    const owned = try arena.dupe(u8, pattern);
    for (owned) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return owned;
}

fn splitSegments(arena: Allocator, pattern: []const u8) ![]const []const u8 {
    var segments = std.array_list.Managed([]const u8).init(arena);
    var start: usize = 0;
    var index: usize = 0;
    while (index <= pattern.len) : (index += 1) {
        if (index == pattern.len or isSeparator(pattern[index])) {
            try segments.append(pattern[start..index]);
            start = index + 1;
        }
    }
    // A trailing slash marks a directory pattern. Upstream's trivial-basename
    // matcher treats `**/foo/` like `**/foo`, and trailing-slash directory
    // patterns must match the directory itself for traversal to prune it.
    if (segments.items.len > 1 and segments.items[segments.items.len - 1].len == 0) {
        segments.items.len -= 1;
    }
    return try segments.toOwnedSlice();
}

fn matchSegments(
    segments: []const []const u8,
    index: usize,
    path: []const u8,
    start: usize,
    ignore_case: bool,
) bool {
    if (index == segments.len) return start == path.len;
    const segment = segments[index];

    if (std.mem.eql(u8, segment, "**")) {
        if (index + 1 == segments.len) return true;
        // `**` matches zero segments ...
        if (matchSegments(segments, index + 1, path, start, ignore_case)) return true;
        // ... or one segment and then the rest.
        var cursor = start;
        while (cursor < path.len) : (cursor += 1) {
            if (isSeparator(path[cursor]) and matchSegments(segments, index, path, cursor + 1, ignore_case)) {
                return true;
            }
        }
        return false;
    }

    var end = start;
    while (end < path.len and !isSeparator(path[end])) : (end += 1) {}
    if (!segmentMatches(segment, path[start..end], ignore_case)) return false;
    if (end == path.len) return onlyGlobStars(segments[index + 1 ..]);
    return matchSegments(segments, index + 1, path, end + 1, ignore_case);
}

/// A trailing `**` can match no segments at all, so it also matches when the
/// path ended at the previous segment.
fn onlyGlobStars(segments: []const []const u8) bool {
    for (segments) |segment| {
        if (!std.mem.eql(u8, segment, "**")) return false;
    }
    return true;
}

fn segmentMatches(pattern: []const u8, text: []const u8, ignore_case: bool) bool {
    return segmentMatchAt(pattern, 0, text, 0, ignore_case);
}

fn segmentMatchAt(
    pattern: []const u8,
    pattern_index: usize,
    text: []const u8,
    text_index: usize,
    ignore_case: bool,
) bool {
    var p = pattern_index;
    var t = text_index;
    while (p < pattern.len) {
        const ch = pattern[p];
        if (ch == '*') {
            var next = p;
            while (next < pattern.len and pattern[next] == '*') next += 1;
            if (segmentMatchAt(pattern, next, text, t, ignore_case)) return true;
            var cursor = t;
            while (cursor < text.len) : (cursor += 1) {
                if (segmentMatchAt(pattern, next, text, cursor + 1, ignore_case)) return true;
            }
            return false;
        }
        if (ch == '?') {
            if (t >= text.len) return false;
            p += 1;
            t += 1;
            continue;
        }
        if (ch == '[') {
            if (p + 1 < pattern.len) {
                if (matchCharClass(pattern, p, text, t, ignore_case)) |class| {
                    if (!class.matched) return false;
                    p = class.next;
                    t += 1;
                    continue;
                }
            }
            if (t >= text.len or !charEquals('[', text[t], ignore_case)) return false;
            p += 1;
            t += 1;
            continue;
        }
        if (t >= text.len or !charEquals(ch, text[t], ignore_case)) return false;
        p += 1;
        t += 1;
    }
    return t == text.len;
}

const CharClassMatch = struct {
    matched: bool,
    /// Index just past the closing `]`.
    next: usize,
};

/// Matches the character class that starts at `start` against `text[text_index]`.
/// Returns null when the class is unterminated, in which case the caller treats
/// `[` as a literal character.
fn matchCharClass(
    pattern: []const u8,
    start: usize,
    text: []const u8,
    text_index: usize,
    ignore_case: bool,
) ?CharClassMatch {
    var index = start + 1;
    var negated = false;
    if (index < pattern.len and (pattern[index] == '!' or pattern[index] == '^')) {
        negated = true;
        index += 1;
    }

    const content_start = index;
    var close: ?usize = null;
    var first = true;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == ']' and !first) {
            close = index;
            break;
        }
        first = false;
    }
    const class_end = close orelse return null;
    if (text_index >= text.len) return .{ .matched = false, .next = class_end + 1 };

    var matched = false;
    const ch = text[text_index];
    var cursor = content_start;
    while (cursor < class_end) {
        const low = pattern[cursor];
        if (cursor + 2 < class_end and pattern[cursor + 1] == '-') {
            const high = pattern[cursor + 2];
            cursor += 3;
            if (charInRange(ch, low, high, ignore_case)) matched = true;
        } else {
            cursor += 1;
            if (charEquals(ch, low, ignore_case)) matched = true;
        }
    }

    return .{
        .matched = if (negated) !matched else matched,
        .next = class_end + 1,
    };
}

fn charInRange(ch: u8, low: u8, high: u8, ignore_case: bool) bool {
    if (ignore_case) {
        const folded = std.ascii.toLower(ch);
        var low_folded = std.ascii.toLower(low);
        var high_folded = std.ascii.toLower(high);
        if (low_folded > high_folded) {
            const swap = low_folded;
            low_folded = high_folded;
            high_folded = swap;
        }
        return folded >= low_folded and folded <= high_folded;
    }
    if (low > high) return false;
    return ch >= low and ch <= high;
}

fn charEquals(a: u8, b: u8, ignore_case: bool) bool {
    if (a == b) return true;
    return ignore_case and std.ascii.toLower(a) == std.ascii.toLower(b);
}

test "glob: basename, globstar and exceptions" {
    var list = try GlobList.init(std.testing.allocator, "**/*.ts, !**/*.test.ts, README.md");
    defer list.deinit();

    try std.testing.expect(list.matches("src/main.ts"));
    try std.testing.expect(!list.matches("src/main.tsx"));
    try std.testing.expect(!list.matches("src/main.test.ts"));
    try std.testing.expect(list.matches("README.md"));
}

test "glob: directory pattern and braces" {
    var list = try GlobList.init(std.testing.allocator, "src/{one,two}/**");
    defer list.deinit();

    try std.testing.expect(list.matches("src/one/a.zig"));
    try std.testing.expect(list.matches("src/two/nested/b.zig"));
    try std.testing.expect(!list.matches("src/three/a.zig"));
}

test "glob: character classes and question mark" {
    var list = try GlobList.init(std.testing.allocator, "file[0-9].txt, file[!0-9].txt, ?.md");
    defer list.deinit();

    try std.testing.expect(list.matches("file1.txt"));
    try std.testing.expect(list.matches("filea.txt"));
    try std.testing.expect(!list.matches("file12.txt"));
    try std.testing.expect(list.matches("a.md"));
    try std.testing.expect(!list.matches("ab.md"));

    // A comma inside a character class is not an expression separator.
    var classes = try GlobList.init(std.testing.allocator, "[a,b].txt");
    defer classes.deinit();
    try std.testing.expect(classes.matches("a.txt"));
    try std.testing.expect(classes.matches(",.txt"));
    try std.testing.expect(!classes.matches("c.txt"));
}

test "glob: expression options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expression = try Expression.init(arena.allocator(), &.{ "**/Build/**", "**/*.log" }, .{
        .trim_for_exclusions = true,
        .ignore_case = true,
    });

    try std.testing.expect(expression.matches("/build"));
    try std.testing.expect(!expression.matches("/build/out"));
    try std.testing.expect(expression.matches("/A/LOG.LOG"));

    const case_sensitive = try Expression.init(arena.allocator(), &.{"**/*.log"}, .{});
    try std.testing.expect(!case_sensitive.matches("/A/LOG.LOG"));
    try std.testing.expect(case_sensitive.matches("/A/a.log"));
}

test "glob: relative pattern bases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expression = try Expression.initSources(arena.allocator(), &.{
        .{ .relative = .{ .base = "/users/data/src", .pattern = "*.js" } },
    }, .{});

    try std.testing.expect(expression.matches("/users/data/src/foo.js"));
    try std.testing.expect(!expression.matches("/users/data/src/foo.ts"));
    try std.testing.expect(!expression.matches("/users/data/src/bar/foo.js"));
    try std.testing.expect(!expression.matches("/other/foo.js"));

    const windows = try Expression.initSources(arena.allocator(), &.{
        .{ .relative = .{ .base = "c:\\users\\data\\src", .pattern = "*.js" } },
    }, .{ .ignore_case = true });
    try std.testing.expect(windows.matches("c:\\users\\data\\src\\foo.js"));
    try std.testing.expect(windows.matches("C:\\USERS\\DATA\\SRC\\FOO.JS"));
    try std.testing.expect(!windows.matches("c:\\users\\data\\src\\bar\\foo.js"));

    const globstar = try Expression.init(arena.allocator(), &.{"**/*.js"}, .{});
    try std.testing.expect(globstar.matches("/users/data/src/foo.js"));
    try std.testing.expect(globstar.matches("/users/data/src/bar/foo.js"));
}

test "glob: exclude exceptions carve paths and children out of excludes" {
    const allocator = std.testing.allocator;

    var node_modules = try parseExcludeExpression(allocator, &.{
        .{ .pattern = "node_modules/*" },
        .{ .pattern = "!node_modules/susa" },
    }, .{});
    defer node_modules.deinit();
    try std.testing.expect(node_modules.matches("node_modules/a", null));
    try std.testing.expect(!node_modules.matches("node_modules/susa", null));
    try std.testing.expect(!node_modules.matches("node_modules/susa/index.js", null));
    try std.testing.expect(!node_modules.matches("src/a.js", null));

    var gulpfile = try parseExcludeExpression(allocator, &.{
        .{ .pattern = "*.js" },
        .{ .pattern = "!gulpfile.js" },
    }, .{});
    defer gulpfile.deinit();
    try std.testing.expect(gulpfile.matches("a.js", null));
    try std.testing.expect(!gulpfile.matches("gulpfile.js", null));

    var dotfiles = try parseExcludeExpression(allocator, &.{
        .{ .pattern = ".*" },
        .{ .pattern = "!.editorconfig" },
        .{ .pattern = "!.gitignore" },
    }, .{});
    defer dotfiles.deinit();
    try std.testing.expect(dotfiles.matches(".env", null));
    try std.testing.expect(!dotfiles.matches(".editorconfig", null));
    try std.testing.expect(!dotfiles.matches(".gitignore", null));

    var vscode = try parseExcludeExpression(allocator, &.{
        .{ .pattern = "**/.vscode" },
        .{ .pattern = "**/.vscode/*" },
        .{ .pattern = "!**/.vscode/launch.json" },
    }, .{});
    defer vscode.deinit();
    try std.testing.expect(vscode.matches("a/.vscode", null));
    try std.testing.expect(vscode.matches("a/.vscode/settings.json", null));
    try std.testing.expect(!vscode.matches("a/.vscode/launch.json", null));
}

test "glob: exceptions on their own exclude nothing" {
    var parsed = try parseExcludeExpression(std.testing.allocator, &.{
        .{ .pattern = "!*.js" },
        .{ .pattern = "!*.ts" },
    }, .{});
    defer parsed.deinit();

    try std.testing.expect(!parsed.matches("a.js", null));
    try std.testing.expect(!parsed.matches("a.ts", null));
    try std.testing.expect(!parsed.matches("a.md", null));
}

test "glob: exceptions win over excludes beneath them" {
    var parsed = try parseExcludeExpression(std.testing.allocator, &.{
        .{ .pattern = "node_modules/*" },
        .{ .pattern = "!node_modules/@types" },
        .{ .pattern = "node_modules/@types/*" },
    }, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.matches("node_modules/a", null));
    try std.testing.expect(!parsed.matches("node_modules/@types/node", null));
}

test "glob: disabled and escaped exception keys" {
    const allocator = std.testing.allocator;

    var disabled = try parseExcludeExpression(allocator, &.{
        .{ .pattern = "*.js" },
        .{ .pattern = "!gulpfile.js", .enabled = false },
    }, .{});
    defer disabled.deinit();
    try std.testing.expect(disabled.matches("gulpfile.js", null));

    var escaped = try parseExcludeExpression(allocator, &.{
        .{ .pattern = "{!}notes.txt" },
    }, .{});
    defer escaped.deinit();
    try std.testing.expect(escaped.matches("!notes.txt", null));
    try std.testing.expect(!escaped.matches("notes.txt", null));

    const escaped_pattern = try escapeExcludeException(allocator, "!notes.txt");
    defer allocator.free(escaped_pattern);
    try std.testing.expectEqualStrings("{!}notes.txt", escaped_pattern);

    const plain_pattern = try escapeExcludeException(allocator, "notes.txt");
    defer allocator.free(plain_pattern);
    try std.testing.expectEqualStrings("notes.txt", plain_pattern);
}

test "glob: exceptions respect ignoreCase" {
    const entries = [_]ExcludeEntry{
        .{ .pattern = "node_modules" },
        .{ .pattern = "node_modules/*" },
        .{ .pattern = "!node_modules/@Types" },
    };

    var insensitive = try parseExcludeExpression(std.testing.allocator, &entries, .{ .ignore_case = true });
    defer insensitive.deinit();
    try std.testing.expect(!insensitive.matches("node_modules/@types", null));

    var sensitive = try parseExcludeExpression(std.testing.allocator, &entries, .{});
    defer sensitive.deinit();
    try std.testing.expect(sensitive.matches("node_modules/@types", null));
}

test "glob: getExcludeExceptions ignores disabled, empty and absolute exceptions" {
    const allocator = std.testing.allocator;
    const entries = [_]ExcludeEntry{
        .{ .pattern = "a" },
        .{ .pattern = "!node_modules/@types/**" },
        .{ .pattern = "!**/Scripts/" },
        .{ .pattern = "!src/*.js" },
        .{ .pattern = "!off", .enabled = false },
        .{ .pattern = "!" },
        .{ .pattern = "!/workspace/keep.js" },
    };
    const exceptions = try getExcludeExceptions(allocator, &entries);
    defer {
        for (exceptions) |exception| allocator.free(exception);
        allocator.free(exceptions);
    }

    try std.testing.expectEqual(@as(usize, 3), exceptions.len);
    try std.testing.expectEqualStrings("node_modules/@types/**", exceptions[0]);
    try std.testing.expectEqualStrings("**/Scripts", exceptions[1]);
    try std.testing.expectEqualStrings("src/*.js", exceptions[2]);
}

test "glob: evaluateExcludeTreeEntry" {
    var parsed = try parseExcludeExpression(std.testing.allocator, &.{
        .{ .pattern = "node_modules" },
        .{ .pattern = "!node_modules/@types" },
    }, .{});
    defer parsed.deinit();

    const leading = evaluateExcludeTreeEntry(&parsed, .{
        .path = "node_modules",
        .is_directory = true,
        .is_parent_excluded = false,
    });
    try std.testing.expect(leading.is_excluded);
    try std.testing.expect(leading.is_visited);

    const excluded_folder = evaluateExcludeTreeEntry(&parsed, .{
        .path = "node_modules/react",
        .is_directory = true,
        .is_parent_excluded = true,
    });
    try std.testing.expect(excluded_folder.is_excluded);
    try std.testing.expect(!excluded_folder.is_visited);

    const excluded_file = evaluateExcludeTreeEntry(&parsed, .{
        .path = "node_modules/a.js",
        .is_directory = false,
        .is_parent_excluded = true,
    });
    try std.testing.expect(excluded_file.is_excluded);
    try std.testing.expect(!excluded_file.is_visited);

    const excepted = evaluateExcludeTreeEntry(&parsed, .{
        .path = "node_modules/@types",
        .is_directory = true,
        .is_parent_excluded = true,
    });
    try std.testing.expect(!excepted.is_excluded);
    try std.testing.expect(excepted.is_visited);

    var hidden_context: u8 = 0;
    const hidden_file = evaluateExcludeTreeEntry(&parsed, .{
        .path = "dist/a.js",
        .is_directory = false,
        .is_parent_excluded = false,
        .is_hidden = .{ .context = &hidden_context, .callback = alwaysHidden },
    });
    try std.testing.expect(hidden_file.is_excluded);
    try std.testing.expect(!hidden_file.is_visited);

    const included = evaluateExcludeTreeEntry(&parsed, .{
        .path = "src/a.js",
        .is_directory = false,
        .is_parent_excluded = false,
    });
    try std.testing.expect(!included.is_excluded);
    try std.testing.expect(included.is_visited);
}

fn alwaysHidden(_: *anyopaque) bool {
    return true;
}

test "glob: couldExceptionMatchBeneath" {
    const Case = struct {
        entries: []const ExcludeEntry,
        folders: []const []const u8,
        expected: []const bool,
    };
    const cases = [_]Case{
        .{
            .entries = &.{ .{ .pattern = "node_modules" }, .{ .pattern = "!node_modules/@types" } },
            .folders = &.{ "node_modules", "node_modules/@types", "node_modules/react", "src" },
            .expected = &.{ true, true, false, false },
        },
        .{
            .entries = &.{ .{ .pattern = "**/*" }, .{ .pattern = "!**/Scripts" } },
            .folders = &.{ "a", "a/b/c" },
            .expected = &.{ true, true },
        },
        .{
            .entries = &.{ .{ .pattern = "*.js" }, .{ .pattern = "!*.ts" } },
            .folders = &.{"src"},
            .expected = &.{false},
        },
        .{
            .entries = &.{ .{ .pattern = "a" }, .{ .pattern = "!a/*/c/**/d.txt" } },
            .folders = &.{ "a", "a/b", "a/b/c", "a/b/x", "a/b/c/e/f" },
            .expected = &.{ true, true, true, false, true },
        },
        .{
            .entries = &.{.{ .pattern = "a" }},
            .folders = &.{"a"},
            .expected = &.{false},
        },
        .{
            .entries = &.{ .{ .pattern = "a" }, .{ .pattern = "!{a/b,c}/keep.txt" } },
            .folders = &.{ "a", "a/b", "c" },
            .expected = &.{ true, true, true },
        },
        .{
            .entries = &.{ .{ .pattern = "a" }, .{ .pattern = "!a/{b/c,d}/keep" } },
            .folders = &.{ "a/b", "a/b/c" },
            .expected = &.{ true, true },
        },
        .{
            .entries = &.{ .{ .pattern = "**" }, .{ .pattern = "!{**,foo}/keep.txt" } },
            .folders = &.{ "a", "a/b" },
            .expected = &.{ true, true },
        },
        .{
            .entries = &.{ .{ .pattern = "node_modules" }, .{ .pattern = "!**.js" } },
            .folders = &.{ "node_modules", "node_modules/a/b" },
            .expected = &.{ false, false },
        },
        .{
            .entries = &.{ .{ .pattern = "src" }, .{ .pattern = "!src/**.keep" } },
            .folders = &.{ "src", "src/a" },
            .expected = &.{ true, false },
        },
    };

    for (cases) |case| {
        var parsed = try parseExcludeExpression(std.testing.allocator, case.entries, .{});
        defer parsed.deinit();
        for (case.folders, case.expected) |folder, expected| {
            try std.testing.expectEqual(expected, parsed.couldExceptionMatchBeneath(folder));
        }
    }
}

test "glob: exceptions do not re-include version control folders unless named" {
    var unnamed = try parseExcludeExpression(std.testing.allocator, &.{
        .{ .pattern = "**/.git" },
        .{ .pattern = "third_party" },
        .{ .pattern = "!third_party/lib" },
    }, .{});
    defer unnamed.deinit();
    try std.testing.expect(unnamed.isExcepted("third_party/lib/a.js", null));
    try std.testing.expect(!unnamed.isExcepted("third_party/lib/.git", null));
    try std.testing.expect(!unnamed.isExcepted("third_party/lib/.git/config", null));
    const git_folder = evaluateExcludeTreeEntry(&unnamed, .{
        .path = "third_party/lib/.git",
        .is_directory = true,
        .is_parent_excluded = false,
    });
    try std.testing.expect(git_folder.is_excluded);
    try std.testing.expect(!git_folder.is_visited);

    var named = try parseExcludeExpression(std.testing.allocator, &.{
        .{ .pattern = "**/.git" },
        .{ .pattern = "!.git/hooks" },
    }, .{});
    defer named.deinit();
    try std.testing.expect(named.isExcepted(".git/hooks/pre-commit", null));
    try std.testing.expect(!named.isExcepted(".git/config", null));
}

test "glob: couldExceptionMatchBeneath skips version control folders unless named" {
    const Case = struct {
        entries: []const ExcludeEntry,
        folders: []const []const u8,
        expected: []const bool,
    };
    const cases = [_]Case{
        .{
            .entries = &.{ .{ .pattern = "**/*" }, .{ .pattern = "!**/Scripts" } },
            .folders = &.{ ".git", "a/.hg/b", "a" },
            .expected = &.{ false, false, true },
        },
        .{
            .entries = &.{ .{ .pattern = "**/*" }, .{ .pattern = "!**/Scripts" }, .{ .pattern = "!.git/hooks" } },
            .folders = &.{ ".git", "a/.hg/b" },
            .expected = &.{ true, false },
        },
        .{
            .entries = &.{ .{ .pattern = "**/*" }, .{ .pattern = "!{.git,.hg}/hooks" } },
            .folders = &.{ ".git", ".hg", ".svn" },
            .expected = &.{ true, true, false },
        },
        .{
            .entries = &.{ .{ .pattern = "**/*" }, .{ .pattern = "!{*,src}/hooks" } },
            .folders = &.{ ".git", "src" },
            .expected = &.{ false, true },
        },
    };

    for (cases) |case| {
        var parsed = try parseExcludeExpression(std.testing.allocator, case.entries, .{});
        defer parsed.deinit();
        for (case.folders, case.expected) |folder, expected| {
            try std.testing.expectEqual(expected, parsed.couldExceptionMatchBeneath(folder));
        }
    }
}

test "glob: expressions without exceptions parse unchanged" {
    var parsed = try parseExcludeExpression(std.testing.allocator, &.{
        .{ .pattern = "**/node_modules" },
    }, .{});
    defer parsed.deinit();

    try std.testing.expect(!parsed.has_exceptions);
    try std.testing.expect(parsed.matches("a/node_modules", null));
    try std.testing.expect(!parsed.matches("a/src", null));
}
