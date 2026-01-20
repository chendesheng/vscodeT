const std = @import("std");
const ArrayList = std.array_list.Managed;
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;
const LanguageId = @import("../encodedTokenAttributes.zig").LanguageId;

pub const NULL_LANGUAGE_ID = "vs.editor.nullLanguage";
pub const PLAINTEXT_LANGUAGE_ID = "plaintext";

pub const LanguageIdCodec = struct {
    _languageIdToLanguage: ArrayList([]const u8),
    _languageToLanguageId: std.StringHashMap(u8),

    pub fn init(allocator: Allocator) !LanguageIdCodec {
        var self = LanguageIdCodec{
            ._languageIdToLanguage = ArrayList([]const u8).init(allocator),
            ._languageToLanguageId = std.StringHashMap(u8).init(allocator),
        };
        try self._register(NULL_LANGUAGE_ID, LanguageId.none);
        try self._register(PLAINTEXT_LANGUAGE_ID, LanguageId.plainText);
        return self;
    }

    pub fn create(allocator: Allocator) !*LanguageIdCodec {
        const self = try allocator.create(LanguageIdCodec);
        self.* = try LanguageIdCodec.init(allocator);
        return self;
    }

    pub fn deinit(self: *LanguageIdCodec) void {
        self._languageIdToLanguage.deinit();
        self._languageToLanguageId.deinit();
    }

    fn _register(self: *LanguageIdCodec, language: []const u8, languageId: u8) !void {
        try self._languageIdToLanguage.append(language);
        try self._languageToLanguageId.put(language, languageId);
    }

    pub fn register(self: *LanguageIdCodec, language: []const u8) !void {
        if (self._languageToLanguageId.get(language)) |_| {
            return;
        }
        const languageId = self._languageIdToLanguage.items.len;
        try self._register(language, languageId);
    }

    pub fn encodeLanguageId(self: *const LanguageIdCodec, language: []const u8) u8 {
        if (self._languageToLanguageId.get(language)) |languageId| {
            return languageId;
        }
        return LanguageId.plainText;
    }

    pub fn decodeLanguageId(self: *const LanguageIdCodec, languageId: u8) []const u8 {
        if (languageId < self._languageIdToLanguage.items.len) {
            return self._languageIdToLanguage.items[languageId];
        }
        return NULL_LANGUAGE_ID;
    }
};
