// Port of `vscode-textmate/src/matcher.ts` (microsoft/vscode-textmate v9.3.2).
//
// Faithfulness notes:
//  * TypeScript closures are represented as an explicit matcher tree. The
//    public behavior is the same: `createMatchers` parses a selector into
//    matcher-with-priority entries, and each matcher is evaluated against a
//    caller-provided input and `matchesName` callback.
//  * The callback receives the identifiers in selector order, exactly like the
//    upstream `matchesName(names, matcherInput)`.
//  * `MatcherSet` owns an arena because the TypeScript version relies on
//    garbage collection for its closures. Call `deinit` when finished.
//  * The selector is copied into that arena so identifier slices stay valid.
//  * Allocator ownership follows `textmate.zig`: an explicit caller allocator,
//    an arena per public result, and unmanaged `std.ArrayList` for internal
//    work.
//
// The tests below are a direct port of `vscode-textmate/src/tests/matcher.test.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn MatchesNameFn(comptime T: type) type {
    return *const fn (identifiers: []const []const u8, input: T) bool;
}

pub fn Matcher(comptime T: type) type {
    return union(enum) {
        /// `matchesName(identifiers, input)`.
        name: []const []const u8,
        /// `!operand`.
        negate: *const Matcher(T),
        /// The false matcher produced by negating a missing operand.
        never,
        /// `every` of the operands; an empty conjunction is true.
        conjunction: []const *const Matcher(T),
        /// `some` of the operands; an empty disjunction is false.
        disjunction: []const *const Matcher(T),

        pub fn evaluate(self: *const Matcher(T), matches_name: MatchesNameFn(T), input: T) bool {
            return switch (self.*) {
                .name => |identifiers| matches_name(identifiers, input),
                .negate => |operand| !operand.evaluate(matches_name, input),
                .never => false,
                .conjunction => |operands| blk: {
                    for (operands) |operand| {
                        if (!operand.evaluate(matches_name, input)) break :blk false;
                    }
                    break :blk true;
                },
                .disjunction => |operands| blk: {
                    for (operands) |operand| {
                        if (operand.evaluate(matches_name, input)) break :blk true;
                    }
                    break :blk false;
                },
            };
        }
    };
}

pub fn MatcherWithPriority(comptime T: type) type {
    return struct {
        matcher: *const Matcher(T),
        priority: i8,
    };
}

pub fn MatcherSet(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        matchers: []MatcherWithPriority(T),

        pub fn deinit(self: *MatcherSet(T)) void {
            self.arena.deinit();
        }

        /// Equivalent to the test helper `matchers.some(m => m.matcher(input))`.
        pub fn any(self: *const MatcherSet(T), matches_name: MatchesNameFn(T), input: T) bool {
            for (self.matchers) |entry| {
                if (entry.matcher.evaluate(matches_name, input)) return true;
            }
            return false;
        }
    };
}

const TokenKind = enum {
    priority_left,
    priority_right,
    identifier,
    minus,
    pipe,
    comma,
    lparen,
    rparen,
};

const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

/// Mirrors the regular expression in `newTokenizer`:
/// `/([LR]:|[\w\.:][\w\.:\-]*|[\,\|\-\(\)])/g`.
///
/// The JavaScript tokenizer skips characters that no alternative matches, so
/// the Zig scanner does the same.
const Tokenizer = struct {
    input: []const u8,
    index: usize = 0,

    fn next(self: *Tokenizer) ?Token {
        while (self.index < self.input.len) {
            const start = self.index;
            if (start + 1 < self.input.len and
                (self.input[start] == 'L' or self.input[start] == 'R') and
                self.input[start + 1] == ':')
            {
                self.index += 2;
                return .{
                    .kind = if (self.input[start] == 'L') .priority_left else .priority_right,
                    .text = self.input[start..self.index],
                };
            }

            const ch = self.input[start];
            if (isIdentifierStart(ch)) {
                self.index += 1;
                while (self.index < self.input.len and isIdentifierContinue(self.input[self.index])) {
                    self.index += 1;
                }
                return .{ .kind = .identifier, .text = self.input[start..self.index] };
            }

            const kind: ?TokenKind = switch (ch) {
                '-' => .minus,
                '|' => .pipe,
                ',' => .comma,
                '(' => .lparen,
                ')' => .rparen,
                else => null,
            };
            if (kind) |token_kind| {
                self.index += 1;
                return .{ .kind = token_kind, .text = self.input[start..self.index] };
            }

            // The upstream tokenizer silently skips unmatched input.
            self.index += 1;
        }
        return null;
    }
};

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == ':';
}

fn isIdentifierContinue(ch: u8) bool {
    return isIdentifierStart(ch) or ch == '-';
}

fn Parser(comptime T: type) type {
    return struct {
        allocator: Allocator,
        tokenizer: Tokenizer,
        token: ?Token,
        matches_name: MatchesNameFn(T),

        fn init(allocator: Allocator, input: []const u8, matches_name: MatchesNameFn(T)) Parser(T) {
            var parser = Parser(T){
                .allocator = allocator,
                .tokenizer = Tokenizer{ .input = input },
                .token = null,
                .matches_name = matches_name,
            };
            parser.token = parser.tokenizer.next();
            return parser;
        }

        fn advance(self: *Parser(T)) void {
            self.token = self.tokenizer.next();
        }

        fn isToken(self: *const Parser(T), kind: TokenKind) bool {
            return self.token != null and self.token.?.kind == kind;
        }

        /// Upstream `isIdentifier` uses the regular expression `/[\w\.:]+/`,
        /// which also matches the `L:`/`R:` priority tokens. Priorities are
        /// consumed by the outer loop; inside parentheses they are names.
        fn isIdentifierToken(self: *const Parser(T)) bool {
            return self.isToken(.identifier) or self.isToken(.priority_left) or self.isToken(.priority_right);
        }

        fn make(self: *Parser(T), matcher: Matcher(T)) Allocator.Error!*const Matcher(T) {
            const result = try self.allocator.create(Matcher(T));
            result.* = matcher;
            return result;
        }

        fn parseOperand(self: *Parser(T)) Allocator.Error!?*const Matcher(T) {
            if (self.isToken(.minus)) {
                self.advance();
                const expression_to_negate = try self.parseOperand();
                if (expression_to_negate) |operand| {
                    return try self.make(.{ .negate = operand });
                }
                // Upstream: `!!expressionToNegate && !expressionToNegate(...)`.
                return try self.make(.never);
            }

            if (self.isToken(.lparen)) {
                self.advance();
                const expression_in_parents = try self.parseInnerExpression();
                if (self.isToken(.rparen)) self.advance();
                return expression_in_parents;
            }

            if (self.isIdentifierToken()) {
                var identifiers: std.ArrayList([]const u8) = .empty;
                while (self.isIdentifierToken()) {
                    try identifiers.append(self.allocator, self.token.?.text);
                    self.advance();
                }
                return try self.make(.{ .name = try identifiers.toOwnedSlice(self.allocator) });
            }

            return null;
        }

        fn parseConjunction(self: *Parser(T)) Allocator.Error!*const Matcher(T) {
            var operands: std.ArrayList(*const Matcher(T)) = .empty;
            while (try self.parseOperand()) |operand| {
                try operands.append(self.allocator, operand);
            }
            return try self.make(.{ .conjunction = try operands.toOwnedSlice(self.allocator) });
        }

        fn parseInnerExpression(self: *Parser(T)) Allocator.Error!*const Matcher(T) {
            var expressions: std.ArrayList(*const Matcher(T)) = .empty;
            while (true) {
                try expressions.append(self.allocator, try self.parseConjunction());
                if (self.isToken(.pipe) or self.isToken(.comma)) {
                    while (self.isToken(.pipe) or self.isToken(.comma)) self.advance();
                } else {
                    break;
                }
            }
            return try self.make(.{ .disjunction = try expressions.toOwnedSlice(self.allocator) });
        }
    };
}

/// Port of `createMatchers(selector, matchesName)`.
///
/// The returned set owns all matcher nodes and identifier slices. `selector`
/// does not need to outlive the call.
pub fn createMatchers(
    comptime T: type,
    allocator: Allocator,
    selector: []const u8,
    matches_name: MatchesNameFn(T),
) Allocator.Error!MatcherSet(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const scratch = arena.allocator();

    const selector_copy = try scratch.dupe(u8, selector);
    var parser = Parser(T).init(scratch, selector_copy, matches_name);
    var results: std.ArrayList(MatcherWithPriority(T)) = .empty;

    while (parser.token != null) {
        var priority: i8 = 0;
        if (parser.token.?.kind == .priority_left) {
            priority = -1;
            parser.advance();
        } else if (parser.token.?.kind == .priority_right) {
            priority = 1;
            parser.advance();
        }

        const matcher = try parser.parseConjunction();
        try results.append(scratch, .{ .matcher = matcher, .priority = priority });

        if (!parser.isToken(.comma)) break;
        parser.advance();
    }

    return .{
        .arena = arena,
        .matchers = try results.toOwnedSlice(scratch),
    };
}
