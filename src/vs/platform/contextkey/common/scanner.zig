// Port of `src/vs/platform/contextkey/common/scanner.ts`.
//
// Terminal adaptations:
// - The input is a UTF-8 byte slice, so offsets are byte offsets (upstream
//   offsets are UTF-16 code units). Token lexemes borrow the input; the input
//   must outlive the tokens.
// - Upstream's `stringRe` includes `\p{L}`. Without Unicode category tables,
//   any non-ASCII byte is accepted as a letter; ASCII membership is exact.
// - `hintDidYouMean` uses the English `nls.localize` strings.
const std = @import("std");
const Allocator = std.mem.Allocator;
const CharCode = @import("../../../base/common/charCode.zig").CharCode;

pub const TokenType = enum {
    LParen,
    RParen,
    Neg,
    Eq,
    NotEq,
    Lt,
    LtEq,
    Gt,
    GtEq,
    RegexOp,
    RegexStr,
    True,
    False,
    In,
    Not,
    And,
    Or,
    Str,
    QuotedStr,
    Error,
    EOF,
};

pub const Token = struct {
    type: TokenType,
    offset: usize,
    lexeme: []const u8 = "",
    is_triple_eq: bool = false,
};

pub const LexingError = struct {
    offset: usize,
    lexeme: []const u8,
    additional_info: ?[]const u8 = null,
};

/// Upstream `Scanner.getLexeme`.
pub fn getLexeme(token: Token) []const u8 {
    return switch (token.type) {
        .LParen => "(",
        .RParen => ")",
        .Neg => "!",
        .Eq => if (token.is_triple_eq) "===" else "==",
        .NotEq => if (token.is_triple_eq) "!==" else "!=",
        .Lt => "<",
        .LtEq => "<=",
        .Gt => ">",
        .GtEq => ">=",
        .RegexOp => "=~",
        .RegexStr, .Str, .QuotedStr, .Error => token.lexeme,
        .True => "true",
        .False => "false",
        .In => "in",
        .Not => "not",
        .And => "&&",
        .Or => "||",
        .EOF => "EOF",
    };
}

const hint_did_you_forget_quote = "Did you forget to open or close the quote?";
const hint_did_you_forget_slash =
    "Did you forget to escape the '/' (slash) character? Put two backslashes before it to escape, e.g., '\\\\/'.";

pub const Scanner = struct {
    allocator: Allocator,
    input: []const u8 = "",
    start: usize = 0,
    current: usize = 0,
    tokens: std.array_list.Managed(Token),
    errors: std.array_list.Managed(LexingError),

    pub fn init(allocator: Allocator) Scanner {
        return .{
            .allocator = allocator,
            .tokens = std.array_list.Managed(Token).init(allocator),
            .errors = std.array_list.Managed(LexingError).init(allocator),
        };
    }

    pub fn deinit(self: *Scanner) void {
        self.tokens.deinit();
        self.errors.deinit();
    }

    pub fn reset(self: *Scanner, value: []const u8) *Scanner {
        self.input = value;
        self.start = 0;
        self.current = 0;
        self.tokens.clearRetainingCapacity();
        self.errors.clearRetainingCapacity();
        return self;
    }

    /// The returned token slice is owned by the scanner and is valid until the
    /// next `reset`/`scan`.
    pub fn scan(self: *Scanner) ![]const Token {
        while (!self.isAtEnd()) {
            // UTF-8 NBSP is not a single CharCode in a byte scanner.
            if (std.mem.startsWith(u8, self.input[self.current..], "\u{00a0}")) {
                self.current += 2;
                self.start = self.current;
                continue;
            }

            self.start = self.current;
            const ch = self.advance();
            switch (ch) {
                CharCode.OpenParen => try self.addToken(.LParen),
                CharCode.CloseParen => try self.addToken(.RParen),
                CharCode.ExclamationMark => {
                    if (self.match(CharCode.Equals)) {
                        const is_triple_eq = self.match(CharCode.Equals);
                        try self.tokens.append(.{ .type = .NotEq, .offset = self.start, .is_triple_eq = is_triple_eq });
                    } else {
                        try self.addToken(.Neg);
                    }
                },
                CharCode.SingleQuote => try self.quotedString(),
                CharCode.Slash => try self.regex(),
                CharCode.Equals => {
                    if (self.match(CharCode.Equals)) {
                        const is_triple_eq = self.match(CharCode.Equals);
                        try self.tokens.append(.{ .type = .Eq, .offset = self.start, .is_triple_eq = is_triple_eq });
                    } else if (self.match(CharCode.Tilde)) {
                        try self.addToken(.RegexOp);
                    } else {
                        try self.addError("Did you mean == or =~?");
                    }
                },
                CharCode.LessThan => try self.addToken(if (self.match(CharCode.Equals)) .LtEq else .Lt),
                CharCode.GreaterThan => try self.addToken(if (self.match(CharCode.Equals)) .GtEq else .Gt),
                CharCode.Ampersand => {
                    if (self.match(CharCode.Ampersand)) {
                        try self.addToken(.And);
                    } else {
                        try self.addError("Did you mean &&?");
                    }
                },
                CharCode.Pipe => {
                    if (self.match(CharCode.Pipe)) {
                        try self.addToken(.Or);
                    } else {
                        try self.addError("Did you mean ||?");
                    }
                },
                CharCode.Space, CharCode.CarriageReturn, CharCode.Tab, CharCode.LineFeed => {},
                else => try self.string(),
            }
        }

        self.start = self.current;
        try self.addToken(.EOF);
        return self.tokens.items;
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.input[self.current] != expected) return false;
        self.current += 1;
        return true;
    }

    fn advance(self: *Scanner) u8 {
        const ch = self.input[self.current];
        self.current += 1;
        return ch;
    }

    fn peek(self: *Scanner) ?u8 {
        if (self.isAtEnd()) return null;
        return self.input[self.current];
    }

    fn addToken(self: *Scanner, token_type: TokenType) !void {
        try self.tokens.append(.{ .type = token_type, .offset = self.start });
    }

    fn addError(self: *Scanner, additional_info: ?[]const u8) !void {
        const lexeme = self.input[self.start..self.current];
        try self.errors.append(.{ .offset = self.start, .lexeme = lexeme, .additional_info = additional_info });
        try self.tokens.append(.{ .type = .Error, .offset = self.start, .lexeme = lexeme });
    }

    fn isStringChar(ch: u8) bool {
        return switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9' => true,
            '_', '<', '>', '-', '.', '/', '\\', ':', '*', '?', '+', '[', ']', '^', ',', '#', '@', ';', '"', '%', '$' => true,
            else => ch >= 0x80,
        };
    }

    fn string(self: *Scanner) !void {
        var end = self.current;
        while (end < self.input.len and isStringChar(self.input[end])) : (end += 1) {
            // `\p{L}` does not match NBSP; it is significant for the offsets
            // of the byte scanner and must not extend the lexeme.
            if (std.mem.startsWith(u8, self.input[end..], "\u{00a0}")) break;
        }
        self.current = end;

        const lexeme = self.input[self.start..self.current];
        const keyword: ?TokenType = if (std.mem.eql(u8, lexeme, "not"))
            .Not
        else if (std.mem.eql(u8, lexeme, "in"))
            .In
        else if (std.mem.eql(u8, lexeme, "false"))
            .False
        else if (std.mem.eql(u8, lexeme, "true"))
            .True
        else
            null;

        if (keyword) |token_type| {
            try self.addToken(token_type);
        } else {
            try self.tokens.append(.{ .type = .Str, .offset = self.start, .lexeme = lexeme });
        }
    }

    fn quotedString(self: *Scanner) !void {
        while (self.peek()) |ch| {
            if (ch == CharCode.SingleQuote) break;
            _ = self.advance();
        }

        if (self.isAtEnd()) {
            try self.addError(hint_did_you_forget_quote);
            return;
        }

        _ = self.advance(); // closing '
        try self.tokens.append(.{
            .type = .QuotedStr,
            .offset = self.start + 1,
            .lexeme = self.input[self.start + 1 .. self.current - 1],
        });
    }

    fn regex(self: *Scanner) !void {
        var p = self.current;
        var in_escape = false;
        var in_character_class = false;

        while (true) {
            if (p >= self.input.len) {
                self.current = p;
                try self.addError(hint_did_you_forget_slash);
                return;
            }

            const ch = self.input[p];
            if (in_escape) {
                in_escape = false;
            } else if (ch == CharCode.Slash and !in_character_class) {
                p += 1;
                break;
            } else if (ch == CharCode.OpenSquareBracket) {
                in_character_class = true;
            } else if (ch == CharCode.Backslash) {
                in_escape = true;
            } else if (ch == CharCode.CloseSquareBracket) {
                in_character_class = false;
            }
            p += 1;
        }

        while (p < self.input.len and isRegexFlag(self.input[p])) : (p += 1) {}

        self.current = p;
        try self.tokens.append(.{
            .type = .RegexStr,
            .offset = self.start,
            .lexeme = self.input[self.start..self.current],
        });
    }

    fn isAtEnd(self: *const Scanner) bool {
        return self.current >= self.input.len;
    }
};

fn isRegexFlag(ch: u8) bool {
    return ch == 'i' or ch == 'g' or ch == 's' or ch == 'm' or ch == 'y' or ch == 'u';
}

test "scan basic expression" {
    var scanner = Scanner.init(std.testing.allocator);
    defer scanner.deinit();
    const tokens = try scanner.reset("foo === bar").scan();
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(TokenType.Str, tokens[0].type);
    try std.testing.expectEqualStrings("foo", tokens[0].lexeme);
    try std.testing.expectEqual(TokenType.Eq, tokens[1].type);
    try std.testing.expect(tokens[1].is_triple_eq);
    try std.testing.expectEqual(TokenType.EOF, tokens[3].type);
}

test "scan unterminated quote" {
    var scanner = Scanner.init(std.testing.allocator);
    defer scanner.deinit();
    const tokens = try scanner.reset("foo === '").scan();
    try std.testing.expectEqual(TokenType.Error, tokens[2].type);
    try std.testing.expectEqualStrings("'", tokens[2].lexeme);
    try std.testing.expectEqual(@as(usize, 1), scanner.errors.items.len);
}
