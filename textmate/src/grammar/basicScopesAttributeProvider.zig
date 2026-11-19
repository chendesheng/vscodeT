// Port of `vscode-textmate/src/grammar/basicScopesAttributeProvider.ts`
// (microsoft/vscode-textmate v9.3.2).
//
// The TypeScript implementation builds a regular expression for embedded
// languages. This port performs the equivalent longest-prefix match directly.
const std = @import("std");
const encoded = @import("../encodedTokenAttributes.zig");
const utils = @import("../utils.zig");
const Allocator = std.mem.Allocator;

pub const EmbeddedLanguage = struct {
    scope_name: []const u8,
    language_id: u32,
};

pub const BasicScopeAttributes = struct {
    language_id: u32,
    token_type: u8,
};

pub const BasicScopeAttributesProvider = struct {
    allocator: Allocator,
    default_attributes: BasicScopeAttributes,
    embedded_languages: []const EmbeddedLanguage,
    cache: std.StringHashMap(BasicScopeAttributes),

    pub fn init(
        allocator: Allocator,
        initial_language_id: u32,
        embedded_languages: []const EmbeddedLanguage,
    ) !BasicScopeAttributesProvider {
        const sorted = try allocator.alloc(EmbeddedLanguage, embedded_languages.len);
        @memcpy(sorted, embedded_languages);
        std.mem.sort(EmbeddedLanguage, sorted, {}, struct {
            fn lessThan(_: void, a: EmbeddedLanguage, b: EmbeddedLanguage) bool {
                if (a.scope_name.len != b.scope_name.len) return a.scope_name.len > b.scope_name.len;
                return utils.strcmp(a.scope_name, b.scope_name) > 0;
            }
        }.lessThan);

        return .{
            .allocator = allocator,
            .default_attributes = .{
                .language_id = initial_language_id,
                .token_type = encoded.OptionalStandardTokenType.not_set,
            },
            .embedded_languages = sorted,
            .cache = std.StringHashMap(BasicScopeAttributes).init(allocator),
        };
    }

    pub fn getDefaultAttributes(self: *const BasicScopeAttributesProvider) BasicScopeAttributes {
        return self.default_attributes;
    }

    pub fn getBasicScopeAttributes(
        self: *BasicScopeAttributesProvider,
        scope_name: ?[]const u8,
    ) !BasicScopeAttributes {
        const scope = scope_name orelse return .{ .language_id = 0, .token_type = 0 };
        if (self.cache.get(scope)) |attributes| return attributes;

        const attributes = BasicScopeAttributes{
            .language_id = self.scopeToLanguage(scope),
            .token_type = self.toStandardTokenType(scope),
        };
        const key = try self.allocator.dupe(u8, scope);
        try self.cache.put(key, attributes);
        return attributes;
    }

    fn scopeToLanguage(self: *const BasicScopeAttributesProvider, scope: []const u8) u32 {
        for (self.embedded_languages) |embedded| {
            if (std.mem.eql(u8, scope, embedded.scope_name)) return embedded.language_id;
            if (scope.len > embedded.scope_name.len and
                std.mem.startsWith(u8, scope, embedded.scope_name) and
                scope[embedded.scope_name.len] == '.')
            {
                return embedded.language_id;
            }
        }
        return 0;
    }

    fn toStandardTokenType(self: *const BasicScopeAttributesProvider, scope: []const u8) u8 {
        _ = self;
        const words = [_]struct { word: []const u8, token_type: u8 }{
            .{ .word = "comment", .token_type = encoded.OptionalStandardTokenType.comment },
            .{ .word = "string", .token_type = encoded.OptionalStandardTokenType.string },
            .{ .word = "regex", .token_type = encoded.OptionalStandardTokenType.regex },
            .{ .word = "meta.embedded", .token_type = encoded.OptionalStandardTokenType.other },
        };

        var best_index: ?usize = null;
        var best_type: u8 = encoded.OptionalStandardTokenType.not_set;
        for (words) |entry| {
            if (findWord(scope, entry.word)) |index| {
                if (best_index == null or index < best_index.?) {
                    best_index = index;
                    best_type = entry.token_type;
                }
            }
        }
        return best_type;
    }
};

fn findWord(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (!std.mem.eql(u8, haystack[index .. index + needle.len], needle)) continue;
        const before_ok = index == 0 or !isWordChar(haystack[index - 1]);
        const after_ok = index + needle.len == haystack.len or !isWordChar(haystack[index + needle.len]);
        if (before_ok and after_ok) return index;
    }
    return null;
}

fn isWordChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "basic scope attributes map embedded languages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var provider = try BasicScopeAttributesProvider.init(arena.allocator(), 1, &.{
        .{ .scope_name = "source.js.embedded.html", .language_id = 2 },
        .{ .scope_name = "source.js", .language_id = 3 },
    });
    try std.testing.expectEqual(@as(u32, 2), (try provider.getBasicScopeAttributes("source.js.embedded.html")).language_id);
    try std.testing.expectEqual(@as(u32, 3), (try provider.getBasicScopeAttributes("source.js")).language_id);
    try std.testing.expectEqual(@as(u32, 0), (try provider.getBasicScopeAttributes("source.css")).language_id);
    try std.testing.expectEqual(encoded.OptionalStandardTokenType.comment, (try provider.getBasicScopeAttributes("comment.line.double-slash.js")).token_type);
    try std.testing.expectEqual(encoded.OptionalStandardTokenType.string, (try provider.getBasicScopeAttributes("string.quoted.double.js")).token_type);
    try std.testing.expectEqual(encoded.OptionalStandardTokenType.regex, (try provider.getBasicScopeAttributes("constant.regex")).token_type);
    try std.testing.expectEqual(encoded.OptionalStandardTokenType.not_set, (try provider.getBasicScopeAttributes("keyword.control")).token_type);
}
