// Port of `src/vs/workbench/services/themes/common/textMateScopeMatcher.ts`.
//
// The browser implementation builds closures per selector; the terminal port
// evaluates the same selector grammar directly against a probe scope, using a
// caller-provided name matcher. Priority markers (`L:`/`R:`) are accepted but
// ignored because probing is done against a single scope path.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ProbeScope = []const []const u8;

pub const MatchesName = *const fn (context: *anyopaque, names: []const []const u8, scope: ProbeScope) i32;

const Parser = struct {
    allocator: Allocator,
    text: []const u8,
    index: usize = 0,
    scope: ProbeScope,
    context: *anyopaque,
    matches_name: MatchesName,

    fn skipSpaces(self: *Parser) void {
        while (self.index < self.text.len and std.ascii.isWhitespace(self.text[self.index])) self.index += 1;
    }

    fn parseExpression(self: *Parser) Allocator.Error!?i32 {
        var result = try self.parseConjunction();
        while (true) {
            self.skipSpaces();
            if (self.index >= self.text.len) break;
            const ch = self.text[self.index];
            if (ch != ',' and ch != '|') break;
            self.index += 1;
            const next = try self.parseConjunction();
            if (next) |value| {
                result = if (result) |current| @max(current, value) else value;
            }
        }
        return result;
    }

    fn parseConjunction(self: *Parser) Allocator.Error!?i32 {
        var result: ?i32 = null;
        while (true) {
            const operand = try self.parseOperand();
            if (operand == null) break;
            result = if (result) |current| @min(current, operand.?) else operand.?;
        }
        return result;
    }

    fn parseOperand(self: *Parser) Allocator.Error!?i32 {
        self.skipSpaces();
        if (self.index >= self.text.len) return null;
        const ch = self.text[self.index];
        if (ch == '-') {
            self.index += 1;
            const inner = try self.parseOperand();
            if (inner == null) return null;
            return if (inner.? < 0) 0 else -1;
        }
        if (ch == '(') {
            self.index += 1;
            const inner = try self.parseExpression();
            self.skipSpaces();
            if (self.index < self.text.len and self.text[self.index] == ')') self.index += 1;
            return inner;
        }
        if (!isIdentifierStart(ch)) return null;
        var names = std.array_list.Managed([]const u8).init(self.allocator);
        defer names.deinit();
        while (true) {
            self.skipSpaces();
            if (self.index >= self.text.len) break;
            const start = self.index;
            while (self.index < self.text.len and isIdentifierChar(self.text[self.index])) self.index += 1;
            if (start == self.index) break;
            try names.append(self.text[start..self.index]);
            self.skipSpaces();
            if (self.index >= self.text.len or !isIdentifierStart(self.text[self.index])) break;
        }
        return self.matches_name(self.context, names.items, self.scope);
    }
};

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == ':' or ch == '-';
}

fn isIdentifierChar(ch: u8) bool {
    return isIdentifierStart(ch) or ch == '\\';
}

/// Evaluates a TextMate scope selector against one probe scope. Returns a
/// negative value when the selector does not match.
pub fn matchesSelector(
    allocator: Allocator,
    selector: []const u8,
    scope: ProbeScope,
    context: *anyopaque,
    matches_name: MatchesName,
) !i32 {
    var parser = Parser{
        .allocator = allocator,
        .text = selector,
        .scope = scope,
        .context = context,
        .matches_name = matches_name,
    };
    // Skip an optional `L:`/`R:` priority marker.
    if (selector.len >= 2 and (selector[0] == 'L' or selector[0] == 'R') and selector[1] == ':') {
        parser.index = 2;
    }
    const result = try parser.parseExpression();
    return result orelse -1;
}

test "textMate scope selectors match names, conjunctions, negation and or" {
    const Context = struct {
        fn match(_: *anyopaque, names: []const []const u8, scope: ProbeScope) i32 {
            var score: i32 = -1;
            for (names) |name| {
                var best: i32 = -1;
                for (scope, 0..) |scope_name, index| {
                    if (std.mem.eql(u8, scope_name, name)) {
                        best = @max(best, @as(i32, @intCast(index + 1)) * 100 + @as(i32, @intCast(name.len)));
                    }
                }
                if (best < 0) return -1;
                score = if (score < 0) best else @min(score, best);
            }
            return score;
        }
    };
    var sink: u8 = 0;
    const context: *anyopaque = @ptrCast(&sink);
    const probe = [_][]const u8{"entity.name.type.class"};
    const allocator = std.testing.allocator;
    try std.testing.expect(try matchesSelector(allocator, "entity.name.type.class", &probe, context, Context.match) > 0);
    try std.testing.expect(try matchesSelector(allocator, "comment", &probe, context, Context.match) < 0);
    try std.testing.expect(try matchesSelector(allocator, "entity.name.type.class|comment", &probe, context, Context.match) > 0);
    try std.testing.expect(try matchesSelector(allocator, "entity.name.type.class comment", &probe, context, Context.match) < 0);
    try std.testing.expectEqual(@as(i32, 0), try matchesSelector(allocator, "-comment", &probe, context, Context.match));
    try std.testing.expectEqual(@as(i32, -1), try matchesSelector(allocator, "-entity.name.type.class", &probe, context, Context.match));
}
