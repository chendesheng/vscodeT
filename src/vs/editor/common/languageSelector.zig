// Port of `src/vs/editor/common/languageSelector.ts`.
//
// Terminal adaptation: the candidate is derived from the editor's `std.Uri`
// (`TextModel.uri()`) rather than upstream's owned `URI` class. Selectors are
// compiled once into a per-registry-entry arena so scoring does not allocate.
// Notebook URIs/types are kept for behavioral fidelity, but the TUI has no
// notebook resolver and always passes `null`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glob = @import("../../base/common/glob.zig");
const std_uri = @import("../../base/common/stdUri.zig");

pub const Pattern = union(enum) {
    string: []const u8,
    relative: glob.RelativePattern,
};

pub const Filter = struct {
    language: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    pattern: ?Pattern = null,
    notebook_type: ?[]const u8 = null,
    has_access_to_all_models: bool = false,
    exclusive: bool = false,
    is_builtin: bool = false,
};

pub const Selector = union(enum) {
    language: []const u8,
    filter: Filter,
    list: []const Selector,
};

pub const Candidate = struct {
    scheme: []const u8,
    fs_path: []const u8,
    language: []const u8,
    synchronized: bool,
    notebook_scheme: ?[]const u8 = null,
    notebook_fs_path: ?[]const u8 = null,
    notebook_type: ?[]const u8 = null,
};

pub const CompiledPattern = struct {
    literal: ?[]const u8 = null,
    expression: ?glob.Expression = null,
};

pub const CompiledFilter = struct {
    language: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    pattern: ?CompiledPattern = null,
    notebook_type: ?[]const u8 = null,
    has_access_to_all_models: bool = false,
    exclusive: bool = false,
    is_builtin: bool = false,
};

pub const CompiledSelector = union(enum) {
    language: []const u8,
    filter: CompiledFilter,
    list: []const CompiledSelector,
};

/// Builds a selector candidate from an editor model URI. The decoded path may
/// point into `arena`.
pub fn candidateFromUri(arena: Allocator, uri: std.Uri, language: []const u8, synchronized: bool) !Candidate {
    return .{
        .scheme = uri.scheme,
        .fs_path = try std_uri.fsPath(uri, arena),
        .language = language,
        .synchronized = synchronized,
    };
}

fn normalizeBase(arena: Allocator, base: []const u8) ![]const u8 {
    if (base.len == 0) return "";
    if (!std.fs.path.isAbsolute(base)) return try arena.dupe(u8, base);
    return std.fs.path.resolveAlloc(arena, &.{base}) catch try arena.dupe(u8, base);
}

fn compilePattern(arena: Allocator, pattern: Pattern) !CompiledPattern {
    switch (pattern) {
        .string => |text| {
            const literal = try arena.dupe(u8, text);
            if (literal.len == 0) return .{ .literal = literal };
            return .{
                .literal = literal,
                .expression = try glob.Expression.initSources(arena, &.{.{ .string = literal }}, .{}),
            };
        },
        .relative => |relative| {
            const base = try normalizeBase(arena, relative.base);
            const pattern_text = try arena.dupe(u8, relative.pattern);
            return .{
                .expression = try glob.Expression.initSources(arena, &.{.{
                    .relative = .{ .base = base, .pattern = pattern_text },
                }}, .{}),
            };
        },
    }
}

pub fn compileSelector(arena: Allocator, selector: Selector) !CompiledSelector {
    switch (selector) {
        .language => |language| return .{ .language = try arena.dupe(u8, language) },
        .filter => |filter| {
            var compiled: CompiledFilter = .{
                .language = if (filter.language) |value| if (value.len > 0) try arena.dupe(u8, value) else null else null,
                .scheme = if (filter.scheme) |value| if (value.len > 0) try arena.dupe(u8, value) else null else null,
                .notebook_type = if (filter.notebook_type) |value| if (value.len > 0) try arena.dupe(u8, value) else null else null,
                .has_access_to_all_models = filter.has_access_to_all_models,
                .exclusive = filter.exclusive,
                .is_builtin = filter.is_builtin,
            };
            if (filter.pattern) |pattern| compiled.pattern = try compilePattern(arena, pattern);
            return .{ .filter = compiled };
        },
        .list => |items| {
            const compiled = try arena.alloc(CompiledSelector, items.len);
            for (items, 0..) |item, index| compiled[index] = try compileSelector(arena, item);
            return .{ .list = compiled };
        },
    }
}

pub fn score(arena: Allocator, selector: Selector, candidate: Candidate) !i32 {
    const compiled = try compileSelector(arena, selector);
    return scoreCompiled(compiled, candidate);
}

pub fn scoreCompiled(selector: CompiledSelector, candidate: Candidate) i32 {
    switch (selector) {
        .list => |items| {
            var best: i32 = 0;
            for (items) |item| {
                const value = scoreCompiled(item, candidate);
                if (value == 10) return 10;
                if (value > best) best = value;
            }
            return best;
        },
        .language => |language| {
            if (!candidate.synchronized) return 0;
            if (std.mem.eql(u8, language, "*")) return 5;
            if (std.mem.eql(u8, language, candidate.language)) return 10;
            return 0;
        },
        .filter => |filter| {
            if (!candidate.synchronized and !filter.has_access_to_all_models) return 0;

            var uri_scheme = candidate.scheme;
            var uri_path = candidate.fs_path;
            if (filter.notebook_type != null and candidate.notebook_fs_path != null) {
                uri_scheme = candidate.notebook_scheme orelse candidate.scheme;
                uri_path = candidate.notebook_fs_path.?;
            }

            var result: i32 = 0;

            if (filter.scheme) |scheme| {
                if (std.mem.eql(u8, scheme, uri_scheme)) {
                    result = 10;
                } else if (std.mem.eql(u8, scheme, "*")) {
                    result = 5;
                } else {
                    return 0;
                }
            }

            if (filter.language) |language| {
                if (std.mem.eql(u8, language, candidate.language)) {
                    result = 10;
                } else if (std.mem.eql(u8, language, "*")) {
                    result = @max(result, 5);
                } else {
                    return 0;
                }
            }

            if (filter.notebook_type) |notebook_type| {
                if (candidate.notebook_type) |candidate_type| {
                    if (std.mem.eql(u8, notebook_type, candidate_type)) {
                        result = 10;
                    } else if (std.mem.eql(u8, notebook_type, "*")) {
                        result = @max(result, 5);
                    } else {
                        return 0;
                    }
                } else {
                    return 0;
                }
            }

            if (filter.pattern) |pattern| {
                var matched = false;
                if (pattern.literal) |literal| {
                    if (std.mem.eql(u8, literal, uri_path)) matched = true;
                }
                if (!matched) {
                    if (pattern.expression) |expression| matched = expression.matches(uri_path);
                }
                if (!matched) return 0;
                result = 10;
            }

            return result;
        },
    }
}

pub fn isExclusive(selector: CompiledSelector) bool {
    switch (selector) {
        .language => return false,
        .list => |items| {
            for (items) |item| {
                if (!isExclusive(item)) return false;
            }
            return true;
        },
        .filter => |filter| return filter.exclusive,
    }
}

pub fn isBuiltin(selector: CompiledSelector) bool {
    switch (selector) {
        .language => return false,
        .list => |items| {
            for (items) |item| {
                if (isBuiltin(item)) return true;
            }
            return false;
        },
        .filter => |filter| return filter.is_builtin,
    }
}

pub fn targetsNotebooks(selector: CompiledSelector) bool {
    switch (selector) {
        .language => return false,
        .list => |items| {
            for (items) |item| {
                if (targetsNotebooks(item)) return true;
            }
            return false;
        },
        .filter => |filter| return filter.notebook_type != null,
    }
}

pub fn selectLanguageIds(selector: CompiledSelector, into: *std.StringHashMap(void)) !void {
    switch (selector) {
        .language => |language| try into.put(language, {}),
        .list => |items| for (items) |item| try selectLanguageIds(item, into),
        .filter => |filter| if (filter.language) |language| try into.put(language, {}),
    }
}
