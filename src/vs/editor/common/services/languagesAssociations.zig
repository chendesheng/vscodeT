// Port of `src/vs/editor/common/services/languagesAssociations.ts`.
//
// Terminal adaptations: the upstream module-global association lists become an
// explicit `LanguageAssociations` instance (no hidden global state), and
// `firstline` regexes are `FirstLineMatcher` callbacks because the port has no
// JavaScript regex engine. Data-URI labels are read from the URI path.
const std = @import("std");
const Allocator = std.mem.Allocator;

const glob = @import("../../../base/common/glob.zig");
const strings = @import("../../../base/common/strings.zig");
const uri_mod = @import("../../../base/common/uri.zig");
const modes_registry = @import("../languages/modesRegistry.zig");

const URI = uri_mod.URI;

/// Upstream stores a `RegExp`; the terminal uses a predicate instead.
pub const FirstLineMatcher = *const fn (line: []const u8) bool;

pub const ILanguageAssociation = struct {
    id: []const u8,
    mime: []const u8,
    filename: ?[]const u8 = null,
    extension: ?[]const u8 = null,
    filepattern: ?[]const u8 = null,
    firstline: ?FirstLineMatcher = null,
};

/// One entry of a `getAssociations` result.
pub const LanguageAssociation = struct {
    id: []const u8,
    mime: []const u8,
};

const AssociationItem = struct {
    id: []const u8,
    mime: []const u8,
    filename: ?[]const u8,
    extension: ?[]const u8,
    filepattern: ?[]const u8,
    firstline: ?FirstLineMatcher,
    user_configured: bool,
    filepattern_on_path: bool,
};

pub const UNKNOWN_ID = "unknown";
pub const UNKNOWN_MIME = "application/unknown";

pub const Result = struct {
    items: [2]LanguageAssociation = undefined,
    len: usize = 0,

    pub fn slice(self: *const Result) []const LanguageAssociation {
        return self.items[0..self.len];
    }
};

/// Port of the association registry and `getAssociations`.
pub const LanguageAssociations = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    registered: std.array_list.Managed(AssociationItem),
    non_user: std.array_list.Managed(AssociationItem),
    user: std.array_list.Managed(AssociationItem),

    pub fn init(allocator: Allocator) !*LanguageAssociations {
        const self = try allocator.create(LanguageAssociations);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .registered = std.array_list.Managed(AssociationItem).init(allocator),
            .non_user = std.array_list.Managed(AssociationItem).init(allocator),
            .user = std.array_list.Managed(AssociationItem).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *LanguageAssociations) void {
        self.registered.deinit();
        self.non_user.deinit();
        self.user.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Registers a platform (built-in) association.
    pub fn registerPlatform(self: *LanguageAssociations, association: ILanguageAssociation) !void {
        try self.register(association, false);
    }

    /// Registers a configured (user) association; it wins over platform ones.
    pub fn registerConfigured(self: *LanguageAssociations, association: ILanguageAssociation) !void {
        try self.register(association, true);
    }

    fn register(self: *LanguageAssociations, association: ILanguageAssociation, user_configured: bool) !void {
        const arena = self.arena.allocator();
        const item = AssociationItem{
            .id = try arena.dupe(u8, association.id),
            .mime = try arena.dupe(u8, association.mime),
            .filename = if (association.filename) |value| try arena.dupe(u8, value) else null,
            .extension = if (association.extension) |value| try arena.dupe(u8, value) else null,
            .filepattern = if (association.filepattern) |value| try arena.dupe(u8, value) else null,
            .firstline = association.firstline,
            .user_configured = user_configured,
            .filepattern_on_path = if (association.filepattern) |value|
                std.mem.indexOfScalar(u8, value, '/') != null
            else
                false,
        };
        try self.registered.append(item);
        if (user_configured) {
            try self.user.append(item);
        } else {
            try self.non_user.append(item);
        }
    }

    /// Removes the platform associations, keeping configured ones.
    pub fn clearPlatform(self: *LanguageAssociations) void {
        self.registered.clearRetainingCapacity();
        for (self.user.items) |item| self.registered.append(item) catch {};
        self.non_user.clearRetainingCapacity();
    }

    /// Removes the configured associations, keeping platform ones.
    pub fn clearConfigured(self: *LanguageAssociations) void {
        self.registered.clearRetainingCapacity();
        for (self.non_user.items) |item| self.registered.append(item) catch {};
        self.user.clearRetainingCapacity();
    }

    /// Given a file, returns the best matching associations: the winner and
    /// the plaintext fallback (or the unknown association).
    pub fn getAssociations(self: *const LanguageAssociations, resource: ?*const URI, first_line: ?[]const u8) Result {
        const path = pathForResource(resource) orelse return unknownResult();
        if (path.len == 0) return unknownResult();
        const filename = std.fs.path.basename(path);

        // 1.) User configured mappings have the highest priority.
        if (self.getAssociationByPath(path, filename, self.user.items)) |association| {
            return matchedResult(association);
        }
        // 2.) Registered mappings have middle priority.
        if (self.getAssociationByPath(path, filename, self.non_user.items)) |association| {
            return matchedResult(association);
        }
        // 3.) First line has the lowest priority.
        if (first_line) |line| {
            if (self.getAssociationByFirstline(line)) |association| {
                return matchedResult(association);
            }
        }
        return unknownResult();
    }

    pub fn getMimeTypes(self: *const LanguageAssociations, resource: ?*const URI, first_line: ?[]const u8) Result {
        return self.getAssociations(resource, first_line);
    }

    pub fn getLanguageIds(self: *const LanguageAssociations, resource: ?*const URI, first_line: ?[]const u8) Result {
        return self.getAssociations(resource, first_line);
    }

    fn getAssociationByPath(
        self: *const LanguageAssociations,
        path: []const u8,
        filename: []const u8,
        associations: []const AssociationItem,
    ) ?*const AssociationItem {
        var filename_match: ?*const AssociationItem = null;
        var pattern_match: ?*const AssociationItem = null;
        var extension_match: ?*const AssociationItem = null;

        // Later registrations win over earlier ones (upstream #20074).
        var index = associations.len;
        while (index > 0) {
            index -= 1;
            const association = &associations[index];

            // First exact name match.
            if (association.filename) |name| {
                if (strings.equalsIgnoreCase(filename, name)) {
                    filename_match = association;
                    break;
                }
            }

            // Longest pattern match.
            if (association.filepattern) |pattern| {
                const is_longer = if (pattern_match) |current|
                    pattern.len > current.filepattern.?.len
                else
                    true;
                if (is_longer) {
                    const target = if (association.filepattern_on_path) path else filename;
                    if (self.patternMatches(pattern, target)) pattern_match = association;
                }
            }

            // Longest extension match.
            if (association.extension) |extension| {
                const is_longer = if (extension_match) |current|
                    extension.len > current.extension.?.len
                else
                    true;
                if (is_longer and strings.endsWithIgnoreCase(filename, extension)) {
                    extension_match = association;
                }
            }
        }

        if (filename_match) |match| return match;
        if (pattern_match) |match| return match;
        if (extension_match) |match| return match;
        return null;
    }

    fn patternMatches(self: *const LanguageAssociations, pattern: []const u8, target: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var expression = glob.Expression.init(arena.allocator(), &.{pattern}, .{ .ignore_case = true }) catch return false;
        return expression.matches(target);
    }

    fn getAssociationByFirstline(self: *const LanguageAssociations, first_line: []const u8) ?*const AssociationItem {
        var line = first_line;
        if (strings.startsWithUTF8BOM(line)) line = line[3..];
        if (line.len == 0) return null;

        var index = self.registered.items.len;
        while (index > 0) {
            index -= 1;
            const association = &self.registered.items[index];
            if (association.firstline) |matcher| {
                if (matcher(line)) return association;
            }
        }
        return null;
    }
};

fn matchedResult(association: *const AssociationItem) Result {
    var result = Result{ .len = 2 };
    result.items[0] = .{ .id = association.id, .mime = association.mime };
    result.items[1] = .{ .id = modes_registry.PLAINTEXT_LANGUAGE_ID, .mime = modes_registry.PLAINTEXT_MIMETYPE };
    return result;
}

fn unknownResult() Result {
    var result = Result{ .len = 1 };
    result.items[0] = .{ .id = UNKNOWN_ID, .mime = UNKNOWN_MIME };
    return result;
}

fn pathForResource(resource: ?*const URI) ?[]const u8 {
    const uri = resource orelse return null;
    if (std.mem.eql(u8, uri.scheme, "file")) return uri.fsPath();
    if (std.mem.eql(u8, uri.scheme, "data")) return dataUriLabel(uri.path);
    return uri.path;
}

/// Reads the `label:` metadata segment of a data URI path.
pub fn dataUriLabel(path: []const u8) ?[]const u8 {
    const metadata_end = std.mem.indexOfScalar(u8, path, ',') orelse return null;
    var segments = std.mem.splitScalar(u8, path[0..metadata_end], ';');
    while (segments.next()) |segment| {
        const prefix = "label:";
        if (std.mem.startsWith(u8, segment, prefix)) return segment[prefix.len..];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests (port of `languagesAssociations.test.ts`)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn matchesRegexesAreNice(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "RegexesAreNice") != null;
}

fn matchesFoobar(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "foobar") != null;
}

fn matchesAzure(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "azure") != null;
}

fn matchesTypeScriptShebang(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "#!")) return false;
    return std.mem.indexOf(u8, line, "deno") != null or
        std.mem.indexOf(u8, line, "bun") != null or
        std.mem.indexOf(u8, line, "ts-node") != null;
}

fn expectMimes(result: *const Result, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, result.len);
    for (expected, result.items[0..result.len]) |expected_mime, item| {
        try testing.expectEqualStrings(expected_mime, item.mime);
    }
}

fn fileUri(allocator: Allocator, path: []const u8) !URI {
    return URI.file(allocator, path);
}

test "languages associations: dynamically register text mime" {
    const associations = try LanguageAssociations.init(testing.allocator);
    defer associations.deinit();

    var foo_monaco = try fileUri(testing.allocator, "foo.monaco");
    defer foo_monaco.deinit();
    var result = associations.getMimeTypes(&foo_monaco, null);
    try expectMimes(&result, &.{"application/unknown"});

    try associations.registerPlatform(.{ .id = "monaco", .extension = ".monaco", .mime = "text/monaco" });
    result = associations.getMimeTypes(&foo_monaco, null);
    try expectMimes(&result, &.{ "text/monaco", "text/plain" });

    var dot_monaco = try fileUri(testing.allocator, ".monaco");
    defer dot_monaco.deinit();
    result = associations.getMimeTypes(&dot_monaco, null);
    try expectMimes(&result, &.{ "text/monaco", "text/plain" });

    try associations.registerPlatform(.{ .id = "codefile", .filename = "Codefile", .mime = "text/code" });
    var codefile = try fileUri(testing.allocator, "Codefile");
    defer codefile.deinit();
    result = associations.getMimeTypes(&codefile, null);
    try expectMimes(&result, &.{ "text/code", "text/plain" });

    var foo_codefile = try fileUri(testing.allocator, "foo.Codefile");
    defer foo_codefile.deinit();
    result = associations.getMimeTypes(&foo_codefile, null);
    try expectMimes(&result, &.{"application/unknown"});

    try associations.registerPlatform(.{ .id = "docker", .filepattern = "Docker*", .mime = "text/docker" });
    var docker_debug = try fileUri(testing.allocator, "Docker-debug");
    defer docker_debug.deinit();
    result = associations.getMimeTypes(&docker_debug, null);
    try expectMimes(&result, &.{ "text/docker", "text/plain" });

    var docker_prod = try fileUri(testing.allocator, "docker-PROD");
    defer docker_prod.deinit();
    result = associations.getMimeTypes(&docker_prod, null);
    try expectMimes(&result, &.{ "text/docker", "text/plain" });

    try associations.registerPlatform(.{
        .id = "niceregex",
        .mime = "text/nice-regex",
        .firstline = matchesRegexesAreNice,
    });
    var random_file = try fileUri(testing.allocator, "Randomfile.noregistration");
    defer random_file.deinit();
    result = associations.getMimeTypes(&random_file, "RegexesAreNice");
    try expectMimes(&result, &.{ "text/nice-regex", "text/plain" });

    result = associations.getMimeTypes(&random_file, "RegexesAreNotNice");
    try expectMimes(&result, &.{"application/unknown"});

    result = associations.getMimeTypes(&codefile, "RegexesAreNice");
    try expectMimes(&result, &.{ "text/code", "text/plain" });
}

test "languages associations: mimes priority" {
    const associations = try LanguageAssociations.init(testing.allocator);
    defer associations.deinit();

    try associations.registerPlatform(.{ .id = "monaco", .extension = ".monaco", .mime = "text/monaco" });
    try associations.registerPlatform(.{ .id = "foobar", .mime = "text/foobar", .firstline = matchesFoobar });

    var foo_monaco = try fileUri(testing.allocator, "foo.monaco");
    defer foo_monaco.deinit();
    var result = associations.getMimeTypes(&foo_monaco, null);
    try expectMimes(&result, &.{ "text/monaco", "text/plain" });

    result = associations.getMimeTypes(&foo_monaco, "foobar");
    try expectMimes(&result, &.{ "text/monaco", "text/plain" });

    try associations.registerPlatform(.{ .id = "docker", .filename = "dockerfile", .mime = "text/winner" });
    try associations.registerPlatform(.{ .id = "docker", .filepattern = "dockerfile*", .mime = "text/looser" });
    var dockerfile = try fileUri(testing.allocator, "dockerfile");
    defer dockerfile.deinit();
    result = associations.getMimeTypes(&dockerfile, null);
    try expectMimes(&result, &.{ "text/winner", "text/plain" });

    try associations.registerPlatform(.{ .id = "azure-looser", .mime = "text/azure-looser", .firstline = matchesAzure });
    try associations.registerPlatform(.{ .id = "azure-winner", .mime = "text/azure-winner", .firstline = matchesAzure });
    var azure = try fileUri(testing.allocator, "azure");
    defer azure.deinit();
    result = associations.getMimeTypes(&azure, "azure");
    try expectMimes(&result, &.{ "text/azure-winner", "text/plain" });
}

test "languages associations: specificity priority 1" {
    const associations = try LanguageAssociations.init(testing.allocator);
    defer associations.deinit();

    try associations.registerPlatform(.{ .id = "monaco2", .extension = ".monaco2", .mime = "text/monaco2" });
    try associations.registerPlatform(.{ .id = "monaco2", .filename = "specific.monaco2", .mime = "text/specific-monaco2" });

    var specific = try fileUri(testing.allocator, "specific.monaco2");
    defer specific.deinit();
    var result = associations.getMimeTypes(&specific, null);
    try expectMimes(&result, &.{ "text/specific-monaco2", "text/plain" });

    var foo = try fileUri(testing.allocator, "foo.monaco2");
    defer foo.deinit();
    result = associations.getMimeTypes(&foo, null);
    try expectMimes(&result, &.{ "text/monaco2", "text/plain" });
}

test "languages associations: specificity priority 2" {
    const associations = try LanguageAssociations.init(testing.allocator);
    defer associations.deinit();

    try associations.registerPlatform(.{ .id = "monaco3", .filename = "specific.monaco3", .mime = "text/specific-monaco3" });
    try associations.registerPlatform(.{ .id = "monaco3", .extension = ".monaco3", .mime = "text/monaco3" });

    var specific = try fileUri(testing.allocator, "specific.monaco3");
    defer specific.deinit();
    var result = associations.getMimeTypes(&specific, null);
    try expectMimes(&result, &.{ "text/specific-monaco3", "text/plain" });

    var foo = try fileUri(testing.allocator, "foo.monaco3");
    defer foo.deinit();
    result = associations.getMimeTypes(&foo, null);
    try expectMimes(&result, &.{ "text/monaco3", "text/plain" });
}

test "languages associations: longest extension wins" {
    const associations = try LanguageAssociations.init(testing.allocator);
    defer associations.deinit();

    try associations.registerPlatform(.{ .id = "monaco", .extension = ".monaco", .mime = "text/monaco" });
    try associations.registerPlatform(.{ .id = "monaco", .extension = ".monaco.xml", .mime = "text/monaco-xml" });
    try associations.registerPlatform(.{ .id = "monaco", .extension = ".monaco.xml.build", .mime = "text/monaco-xml-build" });

    var foo = try fileUri(testing.allocator, "foo.monaco");
    defer foo.deinit();
    var result = associations.getMimeTypes(&foo, null);
    try expectMimes(&result, &.{ "text/monaco", "text/plain" });

    var foo_xml = try fileUri(testing.allocator, "foo.monaco.xml");
    defer foo_xml.deinit();
    result = associations.getMimeTypes(&foo_xml, null);
    try expectMimes(&result, &.{ "text/monaco-xml", "text/plain" });

    var foo_build = try fileUri(testing.allocator, "foo.monaco.xml.build");
    defer foo_build.deinit();
    result = associations.getMimeTypes(&foo_build, null);
    try expectMimes(&result, &.{ "text/monaco-xml-build", "text/plain" });
}

test "languages associations: user configured wins" {
    const associations = try LanguageAssociations.init(testing.allocator);
    defer associations.deinit();

    try associations.registerConfigured(.{ .id = "monaco", .extension = ".monaco.xnl", .mime = "text/monaco" });
    try associations.registerPlatform(.{ .id = "monaco", .extension = ".monaco.xml", .mime = "text/monaco-xml" });

    var foo = try fileUri(testing.allocator, "foo.monaco.xnl");
    defer foo.deinit();
    const result = associations.getMimeTypes(&foo, null);
    try expectMimes(&result, &.{ "text/monaco", "text/plain" });
}

test "languages associations: pattern matches on path if specified" {
    const associations = try LanguageAssociations.init(testing.allocator);
    defer associations.deinit();

    try associations.registerPlatform(.{ .id = "monaco", .filepattern = "**/dot.monaco.xml", .mime = "text/monaco" });
    try associations.registerPlatform(.{ .id = "other", .filepattern = "*ot.other.xml", .mime = "text/other" });

    var uri = try fileUri(testing.allocator, "/some/path/dot.monaco.xml");
    defer uri.deinit();
    const result = associations.getMimeTypes(&uri, null);
    try expectMimes(&result, &.{ "text/monaco", "text/plain" });
}

test "languages associations: last registered mime wins" {
    const associations = try LanguageAssociations.init(testing.allocator);
    defer associations.deinit();

    try associations.registerPlatform(.{ .id = "monaco", .filepattern = "**/dot.monaco.xml", .mime = "text/monaco" });
    try associations.registerPlatform(.{ .id = "other", .filepattern = "**/dot.monaco.xml", .mime = "text/other" });

    var uri = try fileUri(testing.allocator, "/some/path/dot.monaco.xml");
    defer uri.deinit();
    const result = associations.getMimeTypes(&uri, null);
    try expectMimes(&result, &.{ "text/other", "text/plain" });
}

test "languages associations: data uris" {
    const associations = try LanguageAssociations.init(testing.allocator);
    defer associations.deinit();

    try associations.registerPlatform(.{ .id = "data", .extension = ".data", .mime = "text/data" });

    var uri = try URI.parse(testing.allocator, "data:;label:something.data;description:data,", false);
    defer uri.deinit();
    const result = associations.getMimeTypes(&uri, null);
    try expectMimes(&result, &.{ "text/data", "text/plain" });
}

test "languages associations: shebang detection for TypeScript runtimes" {
    const associations = try LanguageAssociations.init(testing.allocator);
    defer associations.deinit();

    try associations.registerPlatform(.{
        .id = "typescript",
        .mime = "text/typescript",
        .firstline = matchesTypeScriptShebang,
    });

    var script = try fileUri(testing.allocator, "script");
    defer script.deinit();

    const matching = [_][]const u8{
        "#!/usr/bin/env deno",
        "#!/usr/bin/env -S deno -A",
        "#!/usr/bin/deno",
        "#!/usr/bin/env bun",
        "#!/usr/bin/env -S bun run",
        "#!/usr/bin/env ts-node",
        "#!/usr/bin/env -S ts-node --esm",
    };
    for (matching) |first_line| {
        const result = associations.getMimeTypes(&script, first_line);
        try expectMimes(&result, &.{ "text/typescript", "text/plain" });
    }

    const not_matching = [_][]const u8{
        "#!/usr/bin/env node",
        "#!/usr/bin/env python",
        "#!/bin/bash",
    };
    for (not_matching) |first_line| {
        const result = associations.getMimeTypes(&script, first_line);
        try expectMimes(&result, &.{"application/unknown"});
    }
}
