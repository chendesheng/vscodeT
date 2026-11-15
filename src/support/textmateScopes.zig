//! Replacement for the `textmate` package's `src/scopes.zig`.
//!
//! `build.zig` copies the pinned package sources into the build cache and
//! substitutes this file for its `scopes.zig`. The package's evaluator stops
//! making progress when it meets a selector character it does not understand,
//! so `parseAnd` spins forever on the `*` wildcards used by the bundled HTML
//! grammars. A grammar with such an injection selector is loaded lazily while
//! parsing markdown, which then hangs tokenization of every later file.
//!
//! The evaluator below keeps the package's selector subset (`|`, `&`, `-`,
//! whitespace, parentheses and `L:`/`R:` priorities), adds wildcard segments
//! and nested commas, and consumes unsupported characters so parsing always
//! makes progress.

const std = @import("std");

fn matchesScope(scopes: []const []const u8, target: []const u8) bool {
    for (scopes) |scope| {
        var scope_it = std.mem.splitScalar(u8, scope, '.');
        var target_it = std.mem.splitScalar(u8, target, '.');
        var matched = true;
        while (target_it.next()) |want| {
            const got = scope_it.next() orelse {
                matched = false;
                break;
            };
            if (!std.mem.eql(u8, want, "*") and !std.mem.eql(u8, want, got)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

const SelectorEvaluator = struct {
    scopes: []const []const u8,
    expr: []const u8,
    pos: usize = 0,

    fn init(scopes: []const []const u8, expr: []const u8) SelectorEvaluator {
        return .{ .scopes = scopes, .expr = expr };
    }

    fn skipWhitespace(self: *SelectorEvaluator) void {
        while (self.pos < self.expr.len and (self.expr[self.pos] == ' ' or self.expr[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn parsePrimary(self: *SelectorEvaluator) bool {
        self.skipWhitespace();
        if (self.pos >= self.expr.len) return false;

        if (self.expr[self.pos] == '(') {
            self.pos += 1;
            const res = self.parseOr();
            self.skipWhitespace();
            if (self.pos < self.expr.len and self.expr[self.pos] == ')') {
                self.pos += 1;
            }
            return res;
        }

        const start = self.pos;
        while (self.pos < self.expr.len) {
            const ch = self.expr[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_' or ch == '*') {
                self.pos += 1;
            } else {
                break;
            }
        }
        if (start == self.pos) {
            // Consume the unsupported character so the callers always make
            // progress; treating it as an unmatched primary is enough for the
            // injector selectors shipped with the bundled grammars.
            self.pos += 1;
            return false;
        }
        const scope_name = self.expr[start..self.pos];
        return matchesScope(self.scopes, scope_name);
    }

    fn parseOr(self: *SelectorEvaluator) bool {
        var res = self.parseAnd();
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.expr.len) break;
            const ch = self.expr[self.pos];
            if (ch != '|' and ch != ',') break;
            self.pos += 1;
            const right = self.parseAnd();
            res = res or right;
        }
        return res;
    }

    fn parseAnd(self: *SelectorEvaluator) bool {
        var res = self.parsePrimary();
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.expr.len) break;
            const ch = self.expr[self.pos];
            if (ch == '|' or ch == ',' or ch == ')') break;
            if (ch == '-') {
                self.pos += 1;
                const right = self.parsePrimary();
                res = res and !right;
            } else if (ch == '&') {
                self.pos += 1;
                const right = self.parsePrimary();
                res = res and right;
            } else {
                const right = self.parsePrimary();
                res = res and right;
            }
        }
        return res;
    }
};

fn matchesAlternative(scopes: []const []const u8, alternative: []const u8) bool {
    var trimmed = std.mem.trim(u8, alternative, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.startsWith(u8, trimmed, "L:") or std.mem.startsWith(u8, trimmed, "R:")) {
        trimmed = trimmed[2..];
    }
    var eval = SelectorEvaluator.init(scopes, trimmed);
    return eval.parseOr();
}

pub fn matchesScopeSelector(scopes: []const []const u8, selector: []const u8) bool {
    // Split top-level alternatives on commas, but let the evaluator handle
    // commas nested in parentheses (the HTML injection selector uses them).
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < selector.len) : (i += 1) {
        switch (selector[i]) {
            '(' => depth += 1,
            ')' => depth -|= 1,
            ',' => if (depth == 0) {
                if (matchesAlternative(scopes, selector[start..i])) return true;
                start = i + 1;
            },
            else => {},
        }
    }
    return matchesAlternative(scopes, selector[start..]);
}

test "scope selector: wildcard segments" {
    const scopes = [_][]const u8{
        "text.html.markdown",
        "meta.paragraph.markdown",
        "meta.tag.block.any.html",
    };
    try std.testing.expect(matchesScopeSelector(&scopes, "meta.tag.*.*.html"));
    try std.testing.expect(!matchesScopeSelector(&scopes, "meta.tag.*.html"));
    try std.testing.expect(matchesScopeSelector(&scopes, "text.html"));
}

test "scope selector: html injection selector terminates" {
    const selector = "R:text.html - (comment.block, text.html meta.embedded, meta.tag.*.*.html)";
    const source = [_][]const u8{"source.zig"};
    try std.testing.expect(!matchesScopeSelector(&source, selector));

    const html = [_][]const u8{"text.html.basic"};
    try std.testing.expect(matchesScopeSelector(&html, selector));

    const tag = [_][]const u8{ "text.html.basic", "meta.tag.block.any.html" };
    try std.testing.expect(!matchesScopeSelector(&tag, selector));
}

test "scope selector: unknown characters still make progress" {
    const scopes = [_][]const u8{"source.zig"};
    try std.testing.expect(!matchesScopeSelector(&scopes, "source.zig @bogus"));
    try std.testing.expect(matchesScopeSelector(&scopes, "source.zig | @bogus"));
}
