const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");
const Uri = std.uri;
const StringHashMap = std.StringHashMap;
const ts_zig = @import("tree-sitter-zig");
const ts_typescript = @import("tree-sitter-typescript");

pub const EDITOR_EXPERIMENTAL_PREFER_TREESITTER = "editor.experimental.preferTreeSitter";
pub const TREESITTER_ALLOWED_SUPPORT = [_][]const u8{ "zig", "typescript", "tsx" };
const TreeSitterLibraryService = @This();

const isTest: bool = false;

_languagesCache: StringHashMap(*const ts.Language),

fn _supportsLanguage(self: *const TreeSitterLibraryService, languageId: []const u8) bool {
    _ = self;

    for (TREESITTER_ALLOWED_SUPPORT) |supportedLanguage| {
        if (std.mem.eql(u8, languageId, supportedLanguage)) {
            return true;
        }
    }
    return false;
}

fn _injectionQueries(self: *TreeSitterLibraryService, languageId: []const u8, kind: []const u8) ?*ts.Query {
    const allocator = self._languagesCache.allocator;
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "languages/{s}/{s}.scm", .{ kind, languageId }) catch {
        return null;
    };
    const file = fs.cwd().openFile(path, .{ .mode = .read_only }) catch {
        return null;
    };
    defer fs.File.close(file);
    const source = fs.File.readToEndAlloc(file, allocator, 1024 * 1024) catch {
        return null;
    };
    defer allocator.free(source);

    if (self._getLanguage(languageId) catch null) |language| {
        return createQuery(language, source) catch {
            return null;
        };
    } else {
        return null;
    }
}

pub fn init(allocator: Allocator) TreeSitterLibraryService {
    return .{
        ._languagesCache = StringHashMap(*const ts.Language).init(allocator),
    };
}

pub fn supportsLanguage(self: *const TreeSitterLibraryService, languageId: []const u8) bool {
    return self._supportsLanguage(languageId);
}

fn _getLanguage(self: *TreeSitterLibraryService, languageId: []const u8) !?*const ts.Language {
    const res = try self._languagesCache.getOrPut(languageId);
    if (!res.found_existing) {
        if (std.mem.eql(u8, languageId, "zig")) {
            res.value_ptr.* = @ptrCast(ts_zig.language());
        } else if (std.mem.eql(u8, languageId, "typescript")) {
            res.value_ptr.* = @ptrCast(ts_typescript.languageTs());
        } else if (std.mem.eql(u8, languageId, "tsx")) {
            res.value_ptr.* = @ptrCast(ts_typescript.languageTsx());
        }
    }
    return res.value_ptr.*;
}

pub fn getLanguage(self: *TreeSitterLibraryService, languageId: []const u8, ignoreSupportsCheck: bool) !?*const ts.Language {
    if (!ignoreSupportsCheck and !self.supportsLanguage(languageId)) {
        return null;
    }
    return try self._getLanguage(languageId);
}

pub fn getInjectionQueries(self: *TreeSitterLibraryService, languageId: []const u8) ?*ts.Query {
    if (!self.supportsLanguage(languageId)) {
        return undefined;
    }
    const query = self._injectionQueries(languageId, "injections");
    return query;
}

pub fn getHighlightingQueries(self: *TreeSitterLibraryService, languageId: []const u8) ?*ts.Query {
    if (!self.supportsLanguage(languageId)) {
        return undefined;
    }
    const query = self._injectionQueries(languageId, "highlights");
    return query;
}

fn createQuery(language: *const ts.Language, querySource: []const u8) !*ts.Query {
    var error_offset: u32 = undefined;
    return try ts.Query.create(language, querySource, &error_offset);
}
