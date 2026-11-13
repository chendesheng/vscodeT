// Subset of `src/vs/base/common/glob.ts` for terminal workspace search.
//
// Upstream parses a full glob expression with brace/character-class support,
// relative patterns and an exclude tree evaluator. The terminal search panel
// needs the common forms only: comma-separated patterns, leading `!`
// exceptions, `*`, `?`, `**`, simple `{a,b}` alternation, a leading `./`, and
// patterns without a slash matching the basename. Character classes, extglob,
// sibling clauses and case-folding options are not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rule = struct {
    pattern: []u8,
    negated: bool,
};

/// A compiled comma-separated glob expression. Evaluation is last-rule-wins,
/// matching upstream's expression semantics.
pub const GlobList = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    rules: std.array_list.Managed(Rule),

    pub fn init(allocator: Allocator, expression: []const u8) !GlobList {
        var self = GlobList{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .rules = std.array_list.Managed(Rule).init(allocator),
        };
        errdefer self.deinit();

        var start: usize = 0;
        var depth: usize = 0;
        var index: usize = 0;
        while (index <= expression.len) : (index += 1) {
            const at_end = index == expression.len;
            if (!at_end) {
                if (expression[index] == '{') depth += 1;
                if (expression[index] == '}' and depth > 0) depth -= 1;
                if (expression[index] != ',' or depth != 0) continue;
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
            try self.appendExpanded(piece, negated);
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
    /// expression matches everything.
    pub fn matches(self: *const GlobList, relative_path: []const u8) bool {
        if (self.rules.items.len == 0) return false;
        const path = normalizePath(relative_path);
        var result = false;
        for (self.rules.items) |rule| {
            if (matchPattern(rule.pattern, path)) result = !rule.negated;
        }
        return result;
    }

    fn appendExpanded(self: *GlobList, pattern: []const u8, negated: bool) !void {
        const arena = self.arena.allocator();
        const open = std.mem.indexOfScalar(u8, pattern, '{');
        if (open) |start| {
            if (std.mem.indexOfScalarPos(u8, pattern, start + 1, '}')) |end| {
                var options = std.mem.splitScalar(u8, pattern[start + 1 .. end], ',');
                var found = false;
                while (options.next()) |option| {
                    found = true;
                    const expanded = try std.fmt.allocPrint(
                        arena,
                        "{s}{s}{s}",
                        .{ pattern[0..start], option, pattern[end + 1 ..] },
                    );
                    try self.appendExpanded(expanded, negated);
                }
                if (found) return;
            }
        }
        try self.rules.append(.{
            .pattern = try arena.dupe(u8, pattern),
            .negated = negated,
        });
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

/// Matches a normalized glob pattern against a normalized relative path.
pub fn matchPattern(pattern_raw: []const u8, path_raw: []const u8) bool {
    if (pattern_raw.len == 0) return path_raw.len == 0;
    var pattern = pattern_raw;
    if (pattern[pattern.len - 1] == '/') {
        // A directory pattern excludes everything below it.
        const dir_pattern = pattern[0 .. pattern.len - 1];
        return path_raw.len > dir_pattern.len and
            std.mem.startsWith(u8, path_raw, dir_pattern) and
            path_raw[dir_pattern.len] == '/';
    }

    if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
        const basename = std.fs.path.basename(path_raw);
        return wildcardMatch(pattern, basename);
    }
    return wildcardMatch(pattern, path_raw);
}

fn wildcardMatch(pattern: []const u8, text: []const u8) bool {
    return wildcardAt(pattern, 0, text, 0);
}

fn wildcardAt(pattern: []const u8, pattern_index: usize, text: []const u8, text_index: usize) bool {
    var p = pattern_index;
    var t = text_index;
    while (p < pattern.len) {
        if (pattern[p] == '*') {
            const double = p + 1 < pattern.len and pattern[p + 1] == '*';
            var next = p + if (double) @as(usize, 2) else 1;
            if (next < pattern.len and pattern[next] == '/') {
                next += 1;
                if (wildcardAt(pattern, next, text, t)) return true;
                var k = t;
                while (k < text.len) : (k += 1) {
                    if (text[k] == '/' and wildcardAt(pattern, next, text, k + 1)) return true;
                }
                return false;
            }
            if (wildcardAt(pattern, next, text, t)) return true;
            var k = t;
            while (k < text.len) : (k += 1) {
                if (!double and text[k] == '/') break;
                if (wildcardAt(pattern, next, text, k + 1)) return true;
            }
            return false;
        }
        if (p >= pattern.len or t >= text.len) return false;
        if (pattern[p] == '?') {
            if (text[t] == '/') return false;
            p += 1;
            t += 1;
            continue;
        }
        if (pattern[p] != text[t]) return false;
        p += 1;
        t += 1;
    }
    return t == text.len;
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
