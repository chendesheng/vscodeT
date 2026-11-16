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
