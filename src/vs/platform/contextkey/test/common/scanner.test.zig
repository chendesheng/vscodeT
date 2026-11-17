// Port of `src/vs/platform/contextkey/test/common/scanner.test.ts`.
//
// Terminal adaptation: offsets are UTF-8 byte offsets and lexemes are slices
// of the input, so the helper compares the token kind, offset and lexeme
// directly (the upstream test builds the same shape with `deepStrictEqual`).
const std = @import("std");
const scanner_module = @import("../../common/scanner.zig");
const Scanner = scanner_module.Scanner;
const Token = scanner_module.Token;

const Expected = struct {
    kind: []const u8,
    offset: usize,
    lexeme: ?[]const u8 = null,
};

fn tokenKind(token: Token) []const u8 {
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
        .RegexStr => "RegexStr",
        .True => "true",
        .False => "false",
        .In => "in",
        .Not => "not",
        .And => "&&",
        .Or => "||",
        .Str => "Str",
        .QuotedStr => "QuotedStr",
        .Error => "ErrorToken",
        .EOF => "EOF",
    };
}

fn expectTokens(input: []const u8, expected: []const Expected) !void {
    var scanner = Scanner.init(std.testing.allocator);
    defer scanner.deinit();
    const tokens = try scanner.reset(input).scan();

    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |entry, token| {
        try std.testing.expectEqualStrings(entry.kind, tokenKind(token));
        try std.testing.expectEqual(entry.offset, token.offset);
        if (entry.lexeme) |lexeme| {
            try std.testing.expectEqualStrings(lexeme, token.lexeme);
        }
    }
}

test "foo.bar<C-shift+2>" {
    try expectTokens("foo.bar<C-shift+2>", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo.bar<C-shift+2>" },
        .{ .kind = "EOF", .offset = 18 },
    });
}

test "!foo" {
    try expectTokens("!foo", &.{
        .{ .kind = "!", .offset = 0 },
        .{ .kind = "Str", .offset = 1, .lexeme = "foo" },
        .{ .kind = "EOF", .offset = 4 },
    });
}

test "foo === bar" {
    try expectTokens("foo === bar", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo" },
        .{ .kind = "===", .offset = 4 },
        .{ .kind = "Str", .offset = 8, .lexeme = "bar" },
        .{ .kind = "EOF", .offset = 11 },
    });
}

test "foo  !== bar" {
    try expectTokens("foo  !== bar", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo" },
        .{ .kind = "!==", .offset = 5 },
        .{ .kind = "Str", .offset = 9, .lexeme = "bar" },
        .{ .kind = "EOF", .offset = 12 },
    });
}

test "!(foo && bar)" {
    try expectTokens("!(foo && bar)", &.{
        .{ .kind = "!", .offset = 0 },
        .{ .kind = "(", .offset = 1 },
        .{ .kind = "Str", .offset = 2, .lexeme = "foo" },
        .{ .kind = "&&", .offset = 6 },
        .{ .kind = "Str", .offset = 9, .lexeme = "bar" },
        .{ .kind = ")", .offset = 12 },
        .{ .kind = "EOF", .offset = 13 },
    });
}

test "=~ " {
    try expectTokens("=~ ", &.{
        .{ .kind = "=~", .offset = 0 },
        .{ .kind = "EOF", .offset = 3 },
    });
}

test "foo =~ /bar/" {
    try expectTokens("foo =~ /bar/", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo" },
        .{ .kind = "=~", .offset = 4 },
        .{ .kind = "RegexStr", .offset = 7, .lexeme = "/bar/" },
        .{ .kind = "EOF", .offset = 12 },
    });
}

test "foo =~ /zee/i" {
    try expectTokens("foo =~ /zee/i", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo" },
        .{ .kind = "=~", .offset = 4 },
        .{ .kind = "RegexStr", .offset = 7, .lexeme = "/zee/i" },
        .{ .kind = "EOF", .offset = 13 },
    });
}

test "foo =~ /zee/gm" {
    try expectTokens("foo =~ /zee/gm", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo" },
        .{ .kind = "=~", .offset = 4 },
        .{ .kind = "RegexStr", .offset = 7, .lexeme = "/zee/gm" },
        .{ .kind = "EOF", .offset = 14 },
    });
}

test "foo in barrr  " {
    try expectTokens("foo in barrr  ", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo" },
        .{ .kind = "in", .offset = 4 },
        .{ .kind = "Str", .offset = 7, .lexeme = "barrr" },
        .{ .kind = "EOF", .offset = 14 },
    });
}

test "resource =~ //FileCabinet/..." {
    try expectTokens(
        "resource =~ //FileCabinet/(SuiteScripts|Templates/(E-mail%20Templates|Marketing%20Templates)|Web%20Site%20Hosting%20Files)(/.*)*$/",
        &.{
            .{ .kind = "Str", .offset = 0, .lexeme = "resource" },
            .{ .kind = "=~", .offset = 9 },
            .{ .kind = "RegexStr", .offset = 12, .lexeme = "//" },
            .{ .kind = "Str", .offset = 14, .lexeme = "FileCabinet/" },
            .{ .kind = "(", .offset = 26 },
            .{ .kind = "Str", .offset = 27, .lexeme = "SuiteScripts" },
            .{ .kind = "ErrorToken", .offset = 39, .lexeme = "|" },
            .{ .kind = "Str", .offset = 40, .lexeme = "Templates/" },
            .{ .kind = "(", .offset = 50 },
            .{ .kind = "Str", .offset = 51, .lexeme = "E-mail%20Templates" },
            .{ .kind = "ErrorToken", .offset = 69, .lexeme = "|" },
            .{ .kind = "Str", .offset = 70, .lexeme = "Marketing%20Templates" },
            .{ .kind = ")", .offset = 91 },
            .{ .kind = "ErrorToken", .offset = 92, .lexeme = "|" },
            .{ .kind = "Str", .offset = 93, .lexeme = "Web%20Site%20Hosting%20Files" },
            .{ .kind = ")", .offset = 121 },
            .{ .kind = "(", .offset = 122 },
            .{ .kind = "RegexStr", .offset = 123, .lexeme = "/.*)*$/" },
            .{ .kind = "EOF", .offset = 130 },
        },
    );
}

test "editorLangId in testely.supportedLangIds && resourceFilename =~ /^.+(.test.(w+))$/gm" {
    try expectTokens("editorLangId in testely.supportedLangIds && resourceFilename =~ /^.+(.test.(w+))$/gm", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "editorLangId" },
        .{ .kind = "in", .offset = 13 },
        .{ .kind = "Str", .offset = 16, .lexeme = "testely.supportedLangIds" },
        .{ .kind = "&&", .offset = 41 },
        .{ .kind = "Str", .offset = 44, .lexeme = "resourceFilename" },
        .{ .kind = "=~", .offset = 61 },
        .{ .kind = "RegexStr", .offset = 64, .lexeme = "/^.+(.test.(w+))$/gm" },
        .{ .kind = "EOF", .offset = 84 },
    });
}

test "!(foo && bar) && baz" {
    try expectTokens("!(foo && bar) && baz", &.{
        .{ .kind = "!", .offset = 0 },
        .{ .kind = "(", .offset = 1 },
        .{ .kind = "Str", .offset = 2, .lexeme = "foo" },
        .{ .kind = "&&", .offset = 6 },
        .{ .kind = "Str", .offset = 9, .lexeme = "bar" },
        .{ .kind = ")", .offset = 12 },
        .{ .kind = "&&", .offset = 14 },
        .{ .kind = "Str", .offset = 17, .lexeme = "baz" },
        .{ .kind = "EOF", .offset = 20 },
    });
}

test "foo.bar:zed==completed - equality with no space" {
    try expectTokens("foo.bar:zed==completed", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo.bar:zed" },
        .{ .kind = "==", .offset = 11 },
        .{ .kind = "Str", .offset = 13, .lexeme = "completed" },
        .{ .kind = "EOF", .offset = 22 },
    });
}

test "a && b || c" {
    try expectTokens("a && b || c", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "a" },
        .{ .kind = "&&", .offset = 2 },
        .{ .kind = "Str", .offset = 5, .lexeme = "b" },
        .{ .kind = "||", .offset = 7 },
        .{ .kind = "Str", .offset = 10, .lexeme = "c" },
        .{ .kind = "EOF", .offset = 11 },
    });
}

test "fooBar && baz.jar && fee.bee<K-loo+1>" {
    try expectTokens("fooBar && baz.jar && fee.bee<K-loo+1>", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "fooBar" },
        .{ .kind = "&&", .offset = 7 },
        .{ .kind = "Str", .offset = 10, .lexeme = "baz.jar" },
        .{ .kind = "&&", .offset = 18 },
        .{ .kind = "Str", .offset = 21, .lexeme = "fee.bee<K-loo+1>" },
        .{ .kind = "EOF", .offset = 37 },
    });
}

test "foo.barBaz<C-r> < 2" {
    try expectTokens("foo.barBaz<C-r> < 2", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo.barBaz<C-r>" },
        .{ .kind = "<", .offset = 16 },
        .{ .kind = "Str", .offset = 18, .lexeme = "2" },
        .{ .kind = "EOF", .offset = 19 },
    });
}

test "foo.bar >= -1" {
    try expectTokens("foo.bar >= -1", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo.bar" },
        .{ .kind = ">=", .offset = 8 },
        .{ .kind = "Str", .offset = 11, .lexeme = "-1" },
        .{ .kind = "EOF", .offset = 13 },
    });
}

test "foo.bar <= -1" {
    try expectTokens("foo.bar <= -1", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo.bar" },
        .{ .kind = "<=", .offset = 8 },
        .{ .kind = "Str", .offset = 11, .lexeme = "-1" },
        .{ .kind = "EOF", .offset = 13 },
    });
}

test "resource =~ /\\/Objects\\/.+\\.xml$/" {
    try expectTokens("resource =~ /\\/Objects\\/.+\\.xml$/", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "resource" },
        .{ .kind = "=~", .offset = 9 },
        .{ .kind = "RegexStr", .offset = 12, .lexeme = "/\\/Objects\\/.+\\.xml$/" },
        .{ .kind = "EOF", .offset = 33 },
    });
}

test "view == vsc-packages-activitybar-folders && vsc-packages-folders-loaded" {
    try expectTokens("view == vsc-packages-activitybar-folders\u{00a0}&& vsc-packages-folders-loaded", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "view" },
        .{ .kind = "==", .offset = 5 },
        .{ .kind = "Str", .offset = 8, .lexeme = "vsc-packages-activitybar-folders" },
        .{ .kind = "&&", .offset = 42 },
        .{ .kind = "Str", .offset = 45, .lexeme = "vsc-packages-folders-loaded" },
        .{ .kind = "EOF", .offset = 72 },
    });
}

test "sfdx:project_opened ..." {
    try expectTokens(
        "sfdx:project_opened && resource =~ /.*\\/functions\\/.*\\/[^\\/]+(\\/[^\\/]+.(ts|js|java|json|toml))?$/ && resourceFilename != package.json && resourceFilename != package-lock.json && resourceFilename != tsconfig.json",
        &.{
            .{ .kind = "Str", .offset = 0, .lexeme = "sfdx:project_opened" },
            .{ .kind = "&&", .offset = 20 },
            .{ .kind = "Str", .offset = 23, .lexeme = "resource" },
            .{ .kind = "=~", .offset = 32 },
            .{ .kind = "RegexStr", .offset = 35, .lexeme = "/.*\\/functions\\/.*\\/[^\\/]+(\\/[^\\/]+.(ts|js|java|json|toml))?$/" },
            .{ .kind = "&&", .offset = 98 },
            .{ .kind = "Str", .offset = 101, .lexeme = "resourceFilename" },
            .{ .kind = "!=", .offset = 118 },
            .{ .kind = "Str", .offset = 121, .lexeme = "package.json" },
            .{ .kind = "&&", .offset = 134 },
            .{ .kind = "Str", .offset = 137, .lexeme = "resourceFilename" },
            .{ .kind = "!=", .offset = 154 },
            .{ .kind = "Str", .offset = 157, .lexeme = "package-lock.json" },
            .{ .kind = "&&", .offset = 175 },
            .{ .kind = "Str", .offset = 178, .lexeme = "resourceFilename" },
            .{ .kind = "!=", .offset = 195 },
            .{ .kind = "Str", .offset = 198, .lexeme = "tsconfig.json" },
            .{ .kind = "EOF", .offset = 211 },
        },
    );
}

test "view =~ quoted regexes" {
    try expectTokens("view =~ '/(servers)/' && viewItem =~ '/^(Starting|Started|Debugging|Stopping|Stopped)/'", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "view" },
        .{ .kind = "=~", .offset = 5 },
        .{ .kind = "QuotedStr", .offset = 9, .lexeme = "/(servers)/" },
        .{ .kind = "&&", .offset = 22 },
        .{ .kind = "Str", .offset = 25, .lexeme = "viewItem" },
        .{ .kind = "=~", .offset = 34 },
        .{ .kind = "QuotedStr", .offset = 38, .lexeme = "/^(Starting|Started|Debugging|Stopping|Stopped)/" },
        .{ .kind = "EOF", .offset = 87 },
    });
}

test "resourcePath =~ /.md(.yml|.txt)*$/gim" {
    try expectTokens("resourcePath =~ /.md(.yml|.txt)*$/gim", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "resourcePath" },
        .{ .kind = "=~", .offset = 13 },
        .{ .kind = "RegexStr", .offset = 16, .lexeme = "/.md(.yml|.txt)*$/gim" },
        .{ .kind = "EOF", .offset = 37 },
    });
}

test "foo === bar'" {
    try expectTokens("foo === bar'", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo" },
        .{ .kind = "===", .offset = 4 },
        .{ .kind = "Str", .offset = 8, .lexeme = "bar" },
        .{ .kind = "ErrorToken", .offset = 11, .lexeme = "'" },
        .{ .kind = "EOF", .offset = 12 },
    });
}

test "foo === '" {
    try expectTokens("foo === '", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo" },
        .{ .kind = "===", .offset = 4 },
        .{ .kind = "ErrorToken", .offset = 8, .lexeme = "'" },
        .{ .kind = "EOF", .offset = 9 },
    });
}

test "foo && 'bar - unterminated single quote" {
    try expectTokens("foo && 'bar", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo" },
        .{ .kind = "&&", .offset = 4 },
        .{ .kind = "ErrorToken", .offset = 7, .lexeme = "'bar" },
        .{ .kind = "EOF", .offset = 11 },
    });
}

test "vim<c-r> == 1 && vim<2 <= 3" {
    try expectTokens("vim<c-r> == 1 && vim<2 <= 3", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "vim<c-r>" },
        .{ .kind = "==", .offset = 9 },
        .{ .kind = "Str", .offset = 12, .lexeme = "1" },
        .{ .kind = "&&", .offset = 14 },
        .{ .kind = "Str", .offset = 17, .lexeme = "vim<2" },
        .{ .kind = "<=", .offset = 23 },
        .{ .kind = "Str", .offset = 26, .lexeme = "3" },
        .{ .kind = "EOF", .offset = 27 },
    });
}

test "vim<c-r>==1 && vim<2<=3" {
    try expectTokens("vim<c-r>==1 && vim<2<=3", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "vim<c-r>" },
        .{ .kind = "==", .offset = 8 },
        .{ .kind = "Str", .offset = 10, .lexeme = "1" },
        .{ .kind = "&&", .offset = 12 },
        .{ .kind = "Str", .offset = 15, .lexeme = "vim<2<" },
        .{ .kind = "ErrorToken", .offset = 21, .lexeme = "=" },
        .{ .kind = "Str", .offset = 22, .lexeme = "3" },
        .{ .kind = "EOF", .offset = 23 },
    });
}

test "foo|bar" {
    try expectTokens("foo|bar", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo" },
        .{ .kind = "ErrorToken", .offset = 3, .lexeme = "|" },
        .{ .kind = "Str", .offset = 4, .lexeme = "bar" },
        .{ .kind = "EOF", .offset = 7 },
    });
}

test "resource =~ //foo/(barr|door/..." {
    try expectTokens(
        "resource =~ //foo/(barr|door/(Foo-Bar%20Templates|Soo%20Looo)|Web%20Site%Jjj%20Llll)(/.*)*$/",
        &.{
            .{ .kind = "Str", .offset = 0, .lexeme = "resource" },
            .{ .kind = "=~", .offset = 9 },
            .{ .kind = "RegexStr", .offset = 12, .lexeme = "//" },
            .{ .kind = "Str", .offset = 14, .lexeme = "foo/" },
            .{ .kind = "(", .offset = 18 },
            .{ .kind = "Str", .offset = 19, .lexeme = "barr" },
            .{ .kind = "ErrorToken", .offset = 23, .lexeme = "|" },
            .{ .kind = "Str", .offset = 24, .lexeme = "door/" },
            .{ .kind = "(", .offset = 29 },
            .{ .kind = "Str", .offset = 30, .lexeme = "Foo-Bar%20Templates" },
            .{ .kind = "ErrorToken", .offset = 49, .lexeme = "|" },
            .{ .kind = "Str", .offset = 50, .lexeme = "Soo%20Looo" },
            .{ .kind = ")", .offset = 60 },
            .{ .kind = "ErrorToken", .offset = 61, .lexeme = "|" },
            .{ .kind = "Str", .offset = 62, .lexeme = "Web%20Site%Jjj%20Llll" },
            .{ .kind = ")", .offset = 83 },
            .{ .kind = "(", .offset = 84 },
            .{ .kind = "RegexStr", .offset = 85, .lexeme = "/.*)*$/" },
            .{ .kind = "EOF", .offset = 92 },
        },
    );
}

test "/((/foo/(?!bar)(.*)/)|((/src/).*/)).*$/" {
    try expectTokens("/((/foo/(?!bar)(.*)/)|((/src/).*/)).*$/", &.{
        .{ .kind = "RegexStr", .offset = 0, .lexeme = "/((/" },
        .{ .kind = "Str", .offset = 4, .lexeme = "foo/" },
        .{ .kind = "(", .offset = 8 },
        .{ .kind = "Str", .offset = 9, .lexeme = "?" },
        .{ .kind = "!", .offset = 10 },
        .{ .kind = "Str", .offset = 11, .lexeme = "bar" },
        .{ .kind = ")", .offset = 14 },
        .{ .kind = "(", .offset = 15 },
        .{ .kind = "Str", .offset = 16, .lexeme = ".*" },
        .{ .kind = ")", .offset = 18 },
        .{ .kind = "RegexStr", .offset = 19, .lexeme = "/)|((/s" },
        .{ .kind = "Str", .offset = 26, .lexeme = "rc/" },
        .{ .kind = ")", .offset = 29 },
        .{ .kind = "Str", .offset = 30, .lexeme = ".*/" },
        .{ .kind = ")", .offset = 33 },
        .{ .kind = ")", .offset = 34 },
        .{ .kind = "Str", .offset = 35, .lexeme = ".*$/" },
        .{ .kind = "EOF", .offset = 39 },
    });
}

test "resourcePath =~ //foo/barr// || ..." {
    try expectTokens(
        "resourcePath =~ //foo/barr// || resourcePath =~ //view/(jarrr|doooor|bees)/(web|templates)// && resourceExtname in foo.Bar",
        &.{
            .{ .kind = "Str", .offset = 0, .lexeme = "resourcePath" },
            .{ .kind = "=~", .offset = 13 },
            .{ .kind = "RegexStr", .offset = 16, .lexeme = "//" },
            .{ .kind = "Str", .offset = 18, .lexeme = "foo/barr//" },
            .{ .kind = "||", .offset = 29 },
            .{ .kind = "Str", .offset = 32, .lexeme = "resourcePath" },
            .{ .kind = "=~", .offset = 45 },
            .{ .kind = "RegexStr", .offset = 48, .lexeme = "//" },
            .{ .kind = "Str", .offset = 50, .lexeme = "view/" },
            .{ .kind = "(", .offset = 55 },
            .{ .kind = "Str", .offset = 56, .lexeme = "jarrr" },
            .{ .kind = "ErrorToken", .offset = 61, .lexeme = "|" },
            .{ .kind = "Str", .offset = 62, .lexeme = "doooor" },
            .{ .kind = "ErrorToken", .offset = 68, .lexeme = "|" },
            .{ .kind = "Str", .offset = 69, .lexeme = "bees" },
            .{ .kind = ")", .offset = 73 },
            .{ .kind = "RegexStr", .offset = 74, .lexeme = "/(web|templates)/" },
            .{ .kind = "ErrorToken", .offset = 91, .lexeme = "/ && resourceExtname in foo.Bar" },
            .{ .kind = "EOF", .offset = 122 },
        },
    );
}

test "foo =~ /file:// || bar" {
    try expectTokens("foo =~ /file:// || bar", &.{
        .{ .kind = "Str", .offset = 0, .lexeme = "foo" },
        .{ .kind = "=~", .offset = 4 },
        .{ .kind = "RegexStr", .offset = 7, .lexeme = "/file:/" },
        .{ .kind = "ErrorToken", .offset = 14, .lexeme = "/ || bar" },
        .{ .kind = "EOF", .offset = 22 },
    });
}
