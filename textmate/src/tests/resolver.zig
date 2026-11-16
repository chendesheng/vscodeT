// Port of `../vscode-textmate/src/tests/resolver.ts`
// (microsoft/vscode-textmate v9.3.2).
const std = @import("std");
const rawGrammar = @import("../rawGrammar.zig");
const basic = @import("../grammar/basicScopesAttributeProvider.zig");
const parseRawGrammar = @import("../parseRawGrammar.zig");
const main = @import("../main.zig");
const Allocator = std.mem.Allocator;

pub const GrammarRegistration = struct {
    language: ?[]const u8,
    scope_name: []const u8,
    path: []const u8,
    embedded_languages: []const basic.EmbeddedLanguage,
};

pub const LanguageRegistration = struct {
    id: []const u8,
    extensions: []const []const u8,
    filenames: []const []const u8,
};

pub const Resolver = struct {
    allocator: Allocator,
    grammars: []GrammarRegistration,
    languages: []LanguageRegistration,
    language2id: std.StringHashMap(u32),
    raw_grammars: std.StringHashMap(*rawGrammar.RawGrammar),
    grammars_parsed: std.json.Parsed(std.json.Value),
    languages_parsed: std.json.Parsed(std.json.Value),
    themes_dir: []const u8,

    pub fn init(allocator: Allocator, themes_dir: []const u8) !Resolver {
        const io = std.Io.Threaded.global_single_threaded.io();
        const grammars_path = try std.fs.path.join(allocator, &.{ themes_dir, "grammars.json" });
        defer allocator.free(grammars_path);
        const languages_path = try std.fs.path.join(allocator, &.{ themes_dir, "languages.json" });
        defer allocator.free(languages_path);

        const grammars_content = try std.Io.Dir.cwd().readFileAlloc(io, grammars_path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(grammars_content);
        const languages_content = try std.Io.Dir.cwd().readFileAlloc(io, languages_path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(languages_content);

        var grammars_parsed = try std.json.parseFromSlice(std.json.Value, allocator, grammars_content, .{});
        errdefer grammars_parsed.deinit();
        var languages_parsed = try std.json.parseFromSlice(std.json.Value, allocator, languages_content, .{});
        errdefer languages_parsed.deinit();

        var language2id = std.StringHashMap(u32).init(allocator);
        errdefer language2id.deinit();

        const language_values = languages_parsed.value.array.items;
        const languages = try allocator.alloc(LanguageRegistration, language_values.len);
        errdefer allocator.free(languages);

        for (language_values, 0..) |language_value, index| {
            const object = language_value.object;
            const id = object.get("id").?.string;
            try language2id.put(id, @intCast(index + 1));
            const extensions = if (object.get("extensions")) |value| try stringArray(allocator, value) else &.{};
            const filenames = if (object.get("filenames")) |value| try stringArray(allocator, value) else &.{};
            languages[index] = .{ .id = id, .extensions = extensions, .filenames = filenames };
        }

        const grammar_values = grammars_parsed.value.array.items;
        const grammars = try allocator.alloc(GrammarRegistration, grammar_values.len);
        errdefer allocator.free(grammars);

        for (grammar_values, 0..) |grammar_value, index| {
            const object = grammar_value.object;
            const language = if (object.get("language")) |value| value.string else null;
            const scope_name = object.get("scopeName").?.string;
            const relative_path = object.get("path").?.string;
            const full_path = try std.fs.path.join(allocator, &.{ themes_dir, relative_path });

            var embedded: []basic.EmbeddedLanguage = &.{};
            if (object.get("embeddedLanguages")) |value| {
                var list: std.ArrayList(basic.EmbeddedLanguage) = .empty;
                errdefer list.deinit(allocator);
                var iterator = value.object.iterator();
                while (iterator.next()) |entry| {
                    const language_id = language2id.get(entry.value_ptr.string) orelse continue;
                    try list.append(allocator, .{
                        .scope_name = entry.key_ptr.*,
                        .language_id = language_id,
                    });
                }
                embedded = try list.toOwnedSlice(allocator);
            }

            grammars[index] = .{
                .language = language,
                .scope_name = scope_name,
                .path = full_path,
                .embedded_languages = embedded,
            };
        }

        return .{
            .allocator = allocator,
            .grammars = grammars,
            .languages = languages,
            .language2id = language2id,
            .raw_grammars = std.StringHashMap(*rawGrammar.RawGrammar).init(allocator),
            .grammars_parsed = grammars_parsed,
            .languages_parsed = languages_parsed,
            .themes_dir = try allocator.dupe(u8, themes_dir),
        };
    }

    pub fn deinit(self: *Resolver) void {
        var raw_iterator = self.raw_grammars.valueIterator();
        while (raw_iterator.next()) |value| {
            value.*.deinit();
            self.allocator.destroy(value.*);
        }
        self.raw_grammars.deinit();
        for (self.grammars) |grammar| {
            self.allocator.free(grammar.path);
            self.allocator.free(grammar.embedded_languages);
        }
        for (self.languages) |language| {
            self.allocator.free(language.extensions);
            self.allocator.free(language.filenames);
        }
        self.allocator.free(self.grammars);
        self.allocator.free(self.languages);
        self.language2id.deinit();
        self.allocator.free(self.themes_dir);
        self.grammars_parsed.deinit();
        self.languages_parsed.deinit();
    }

    fn stringArray(allocator: Allocator, value: std.json.Value) ![]const []const u8 {
        const items = value.array.items;
        const result = try allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, i| result[i] = item.string;
        return result;
    }

    pub fn findLanguageByExtension(self: *const Resolver, file_extension: []const u8) ?u32 {
        for (self.languages) |language| {
            for (language.extensions) |candidate| {
                if (std.mem.eql(u8, candidate, file_extension)) return self.language2id.get(language.id);
            }
        }
        return null;
    }

    pub fn findLanguageByFilename(self: *const Resolver, filename: []const u8) ?u32 {
        for (self.languages) |language| {
            for (language.filenames) |candidate| {
                if (std.mem.eql(u8, candidate, filename)) return self.language2id.get(language.id);
            }
        }
        return null;
    }

    pub fn findGrammarByLanguage(self: *const Resolver, language_id: u32) ?*const GrammarRegistration {
        var found: ?[]const u8 = null;
        for (self.languages, 0..) |language, index| {
            if (index + 1 == language_id) {
                found = language.id;
                break;
            }
        }
        const language_name = found orelse return null;
        for (self.grammars) |*grammar| {
            if (grammar.language) |candidate| {
                if (std.mem.eql(u8, candidate, language_name)) return grammar;
            }
        }
        return null;
    }

    pub fn loadGrammar(context: *anyopaque, scope_name: []const u8) anyerror!?*rawGrammar.RawGrammar {
        const self: *Resolver = @ptrCast(@alignCast(context));
        if (self.raw_grammars.get(scope_name)) |cached| return cached;

        for (self.grammars) |grammar| {
            if (!std.mem.eql(u8, grammar.scope_name, scope_name)) continue;
            const io = std.Io.Threaded.global_single_threaded.io();
            const content = try std.Io.Dir.cwd().readFileAlloc(io, grammar.path, self.allocator, .limited(64 * 1024 * 1024));
            defer self.allocator.free(content);
            const raw = try self.allocator.create(rawGrammar.RawGrammar);
            errdefer self.allocator.destroy(raw);
            raw.* = try parseRawGrammar.parseRawGrammar(self.allocator, content, grammar.path);
            try self.raw_grammars.put(grammar.scope_name, raw);
            return raw;
        }
        return null;
    }

    pub fn registryOptions(self: *Resolver, onig_lib: main.IOnigLib, raw_theme: *const @import("../theme.zig").RawTheme) main.RegistryOptions {
        return .{
            .onig_lib = onig_lib,
            .theme = raw_theme,
            .context = self,
            .load_grammar = loadGrammar,
        };
    }
};

pub fn extension(path: []const u8) []const u8 {
    const basename_start = std.mem.lastIndexOfAny(u8, path, "/\\") orelse 0;
    const base = path[basename_start..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    return base[dot..];
}

pub fn basename(path: []const u8) []const u8 {
    const start = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[start + 1 ..];
}
