// Port of `src/vs/workbench/services/search/test/common/ignoreFile.test.ts`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const IgnoreFile = @import("../../common/ignoreFile.zig").IgnoreFile;

/// Runs the same assertion as the upstream `runAssert` helper, with and
/// without the `/someFolder` prefix, against a freshly built `IgnoreFile`.
const Harness = struct {
    allocator: Allocator,
    contents: []const u8,
    location: []const u8,
    ignore_case: bool = false,
    parent: ?*const IgnoreFile = null,

    fn ignoreMatch(self: Harness, input: []const u8) !void {
        try self.run(input, true, false);
    }

    fn noIgnoreMatch(self: Harness, input: []const u8) !void {
        try self.run(input, false, false);
    }

    fn traverses(self: Harness, input: []const u8) !void {
        try self.run(input, true, true);
    }

    fn noTraverses(self: Harness, input: []const u8) !void {
        try self.run(input, false, true);
    }

    fn run(self: Harness, input: []const u8, should_match: bool, traverse: bool) !void {
        try self.runWithPrefix("", input, should_match, traverse);
        try self.runWithPrefix("/someFolder", input, should_match, traverse);
    }

    fn runWithPrefix(
        self: Harness,
        prefix: []const u8,
        input: []const u8,
        should_match: bool,
        traverse: bool,
    ) !void {
        const is_dir = std.mem.endsWith(u8, input, "/");
        const raw_input = if (is_dir) input[0 .. input.len - 1] else input;

        const location = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, self.location });
        defer self.allocator.free(location);
        const path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, raw_input });
        defer self.allocator.free(path);

        const ignore_file = try IgnoreFile.init(
            self.allocator,
            self.contents,
            location,
            self.parent,
            self.ignore_case,
        );
        defer ignore_file.deinit();

        if (traverse) {
            const included = try ignore_file.isPathIncludedInTraversal(path, is_dir);
            try std.testing.expectEqual(should_match, included);
        } else {
            const ignored = try ignore_file.isArbitraryPathIgnored(path, is_dir);
            try std.testing.expectEqual(should_match, ignored);
        }
    }
};

/// Upstream `runTest` in "various advanced constructs found in popular repos":
/// `included` paths must not be ignored, `excluded` paths must be ignored.
fn runPattern(allocator: Allocator, pattern: []const u8, included: []const []const u8, excluded: []const []const u8) !void {
    const harness = Harness{ .allocator = allocator, .contents = pattern, .location = "/" };
    for (included) |input| try harness.noIgnoreMatch(input);
    for (excluded) |input| try harness.ignoreMatch(input);
}

test "Parsing .gitignore files: paths with trailing slashes do not match files" {
    const allocator = std.testing.allocator;
    const h = Harness{ .allocator = allocator, .contents = "node_modules/\n", .location = "/" };

    try h.noIgnoreMatch("/node_modules");
    try h.ignoreMatch("/node_modules/");

    try h.noIgnoreMatch("/inner/node_modules");
    try h.ignoreMatch("/inner/node_modules/");
}

test "Parsing .gitignore files: parsing simple gitignore files" {
    const allocator = std.testing.allocator;
    var h = Harness{ .allocator = allocator, .contents = "node_modules\nout\n", .location = "/" };

    try h.ignoreMatch("/node_modules");
    try h.noTraverses("/node_modules");
    try h.ignoreMatch("/node_modules/file");
    try h.ignoreMatch("/dir/node_modules");
    try h.ignoreMatch("/dir/node_modules/file");

    try h.ignoreMatch("/out");
    try h.noTraverses("/out");
    try h.ignoreMatch("/out/file");
    try h.ignoreMatch("/dir/out");
    try h.ignoreMatch("/dir/out/file");

    h.contents = "/node_modules\n/out\n";

    try h.ignoreMatch("/node_modules");
    try h.ignoreMatch("/node_modules/file");
    try h.noIgnoreMatch("/dir/node_modules");
    try h.noIgnoreMatch("/dir/node_modules/file");

    try h.ignoreMatch("/out");
    try h.ignoreMatch("/out/file");
    try h.noIgnoreMatch("/dir/out");
    try h.noIgnoreMatch("/dir/out/file");

    h.contents = "node_modules/\nout/\n";

    try h.noIgnoreMatch("/node_modules");
    try h.ignoreMatch("/node_modules/");
    try h.ignoreMatch("/node_modules/file");
    try h.ignoreMatch("/dir/node_modules/");
    try h.noIgnoreMatch("/dir/node_modules");
    try h.ignoreMatch("/dir/node_modules/file");

    try h.ignoreMatch("/out/");
    try h.noIgnoreMatch("/out");
    try h.ignoreMatch("/out/file");
    try h.noIgnoreMatch("/dir/out");
    try h.ignoreMatch("/dir/out/");
    try h.ignoreMatch("/dir/out/file");
}

test "Parsing .gitignore files: parsing files-in-folder exclude" {
    const allocator = std.testing.allocator;
    var h = Harness{ .allocator = allocator, .contents = "node_modules/*\n", .location = "/" };

    try h.noIgnoreMatch("/node_modules");
    try h.noIgnoreMatch("/node_modules/");
    try h.traverses("/node_modules");
    try h.traverses("/node_modules/");
    try h.ignoreMatch("/node_modules/something");
    try h.noTraverses("/node_modules/something");
    try h.ignoreMatch("/node_modules/something/else");
    try h.ignoreMatch("/node_modules/@types");
    try h.noTraverses("/node_modules/@types");

    h.contents = "node_modules/**/*\n";

    try h.noIgnoreMatch("/node_modules");
    try h.noIgnoreMatch("/node_modules/");
    try h.ignoreMatch("/node_modules/something");
    try h.ignoreMatch("/node_modules/something/else");
    try h.ignoreMatch("/node_modules/@types");
}

test "Parsing .gitignore files: parsing simple negations" {
    const allocator = std.testing.allocator;
    var h = Harness{
        .allocator = allocator,
        .contents = "node_modules/*\n!node_modules/@types\n",
        .location = "/",
    };

    try h.noIgnoreMatch("/node_modules");
    try h.traverses("/node_modules");

    try h.ignoreMatch("/node_modules/something");
    try h.noTraverses("/node_modules/something");
    try h.ignoreMatch("/node_modules/something/else");

    try h.noIgnoreMatch("/node_modules/@types");
    try h.traverses("/node_modules/@types");
    try h.traverses("/node_modules/@types/boop");

    h.contents = "*.log\n!important.log\n";

    try h.ignoreMatch("/test.log");
    try h.ignoreMatch("/inner/test.log");

    try h.noIgnoreMatch("/important.log");
    try h.noIgnoreMatch("/inner/important.log");

    try h.noTraverses("/test.log");
    try h.noTraverses("/inner/test.log");
    try h.traverses("/important.log");
    try h.traverses("/inner/important.log");
}

test "Parsing .gitignore files: nested .gitignores" {
    const allocator = std.testing.allocator;
    var h = Harness{ .allocator = allocator, .contents = "node_modules\nout\n", .location = "/inner/" };

    try h.ignoreMatch("/inner/node_modules");
    try h.ignoreMatch("/inner/more/node_modules");

    h.contents = "/node_modules\n/out\n";

    try h.ignoreMatch("/inner/node_modules");
    try h.noIgnoreMatch("/inner/more/node_modules");
    try h.noIgnoreMatch("/node_modules");

    h.contents = "node_modules/\nout/\n";

    try h.noIgnoreMatch("/inner/node_modules");
    try h.ignoreMatch("/inner/node_modules/");
    try h.noIgnoreMatch("/inner/more/node_modules");
    try h.ignoreMatch("/inner/more/node_modules/");
    try h.noIgnoreMatch("/node_modules");
}

test "Parsing .gitignore files: file extension matches" {
    const allocator = std.testing.allocator;
    var h = Harness{ .allocator = allocator, .contents = "*.js\n", .location = "/" };

    try h.noIgnoreMatch("/myFile.ts");
    try h.ignoreMatch("/myFile.js");
    try h.noIgnoreMatch("/inner/myFile.ts");
    try h.ignoreMatch("/inner/myFile.js");

    h.contents = "/*.js";
    try h.noIgnoreMatch("/myFile.ts");
    try h.ignoreMatch("/myFile.js");
    try h.noIgnoreMatch("/inner/myFile.ts");
    try h.noIgnoreMatch("/inner/myFile.js");

    h.contents = "**/*.js";
    try h.noIgnoreMatch("/myFile.ts");
    try h.ignoreMatch("/myFile.js");
    try h.noIgnoreMatch("/inner/myFile.ts");
    try h.ignoreMatch("/inner/myFile.js");
    try h.noIgnoreMatch("/inner/more/myFile.ts");
    try h.ignoreMatch("/inner/more/myFile.js");

    h.contents = "inner/*.js";
    try h.noIgnoreMatch("/myFile.ts");
    try h.noIgnoreMatch("/myFile.js");
    try h.noIgnoreMatch("/inner/myFile.ts");
    try h.ignoreMatch("/inner/myFile.js");
    try h.noIgnoreMatch("/inner/more/myFile.ts");
    try h.noIgnoreMatch("/inner/more/myFile.js");

    h.contents = "/inner/*.js";
    try h.noIgnoreMatch("/myFile.ts");
    try h.noIgnoreMatch("/myFile.js");
    try h.noIgnoreMatch("/inner/myFile.ts");
    try h.ignoreMatch("/inner/myFile.js");
    try h.noIgnoreMatch("/inner/more/myFile.ts");
    try h.noIgnoreMatch("/inner/more/myFile.js");

    h.contents = "**/inner/*.js";
    try h.noIgnoreMatch("/myFile.ts");
    try h.noIgnoreMatch("/myFile.js");
    try h.noIgnoreMatch("/inner/myFile.ts");
    try h.ignoreMatch("/inner/myFile.js");
    try h.noIgnoreMatch("/inner/more/myFile.ts");
    try h.noIgnoreMatch("/inner/more/myFile.js");

    h.contents = "**/inner/**/*.js";
    try h.noIgnoreMatch("/myFile.ts");
    try h.noIgnoreMatch("/myFile.js");
    try h.noIgnoreMatch("/inner/myFile.ts");
    try h.ignoreMatch("/inner/myFile.js");
    try h.noIgnoreMatch("/inner/more/myFile.ts");
    try h.ignoreMatch("/inner/more/myFile.js");

    h.contents = "**/more/*.js";
    try h.noIgnoreMatch("/myFile.ts");
    try h.noIgnoreMatch("/myFile.js");
    try h.noIgnoreMatch("/inner/myFile.ts");
    try h.noIgnoreMatch("/inner/myFile.js");
    try h.noIgnoreMatch("/inner/more/myFile.ts");
    try h.ignoreMatch("/inner/more/myFile.js");
}

test "Parsing .gitignore files: real world example: vscode-js-debug" {
    const allocator = std.testing.allocator;
    const contents =
        \\.cache/
        \\.profile/
        \\.cdp-profile/
        \\.headless-profile/
        \\.vscode-test/
        \\.DS_Store
        \\node_modules/
        \\out/
        \\dist
        \\/coverage
        \\/.nyc_output
        \\demos/web-worker/vscode-pwa-dap.log
        \\demos/web-worker/vscode-pwa-cdp.log
        \\.dynamic-testWorkspace
        \\**/test/**/*.actual
        \\/testWorkspace/web/tmp
        \\/testWorkspace/**/debug.log
        \\/testWorkspace/webview/win/true/
        \\*.cpuprofile
    ;
    const h = Harness{ .allocator = allocator, .contents = contents, .location = "/" };

    const included = [_][]const u8{
        "/distro",

        "/inner/coverage",
        "/inner/.nyc_output",

        "/inner/demos/web-worker/vscode-pwa-dap.log",
        "/inner/demos/web-worker/vscode-pwa-cdp.log",

        "/testWorkspace/webview/win/true",

        "/a/best/b/c.actual",
        "/best/b/c.actual",
    };
    for (included) |input| try h.noIgnoreMatch(input);

    const excluded = [_][]const u8{
        "/.profile/",
        "/inner/.profile/",

        "/.DS_Store",
        "/inner/.DS_Store",

        "/coverage",
        "/.nyc_output",

        "/demos/web-worker/vscode-pwa-dap.log",
        "/demos/web-worker/vscode-pwa-cdp.log",

        "/.dynamic-testWorkspace",
        "/inner/.dynamic-testWorkspace",

        "/test/.actual",
        "/test/hello.actual",
        "/a/test/.actual",
        "/a/test/b.actual",
        "/a/test/b/.actual",
        "/a/test/b/c.actual",
        "/a/b/test/.actual",
        "/a/b/test/f/c.actual",

        "/testWorkspace/web/tmp",

        "/testWorkspace/debug.log",
        "/testWorkspace/a/debug.log",
        "/testWorkspace/a/b/debug.log",

        "/testWorkspace/webview/win/true/",

        "/.cpuprofile",
        "/a.cpuprofile",
        "/aa/a.cpuprofile",
        "/aaa/aa/a.cpuprofile",
    };
    for (excluded) |input| try h.ignoreMatch(input);
}

test "Parsing .gitignore files: real world example: vscode" {
    const allocator = std.testing.allocator;
    const contents =
        \\.DS_Store
        \\.cache
        \\npm-debug.log
        \\Thumbs.db
        \\node_modules/
        \\.build/
        \\extensions/**/dist/
        \\/out*/
        \\/extensions/**/out/
        \\src/vs/server
        \\resources/server
        \\build/node_modules
        \\coverage/
        \\test_data/
        \\test-results/
        \\yarn-error.log
        \\vscode.lsif
        \\vscode.db
        \\/.profile-oss
    ;
    const h = Harness{ .allocator = allocator, .contents = contents, .location = "/" };

    const included = [_][]const u8{
        "/inner/extensions/dist",
        "/inner/extensions/boop/dist/test",
        "/inner/extensions/boop/doop/dist",
        "/inner/extensions/boop/doop/dist/test",
        "/inner/extensions/boop/doop/dist/test",

        "/inner/extensions/out/test",
        "/inner/extensions/boop/out",
        "/inner/extensions/boop/out/test",

        "/inner/out/",
        "/inner/out/test",
        "/inner/out1/",
        "/inner/out1/test",
        "/inner/out2/",
        "/inner/out2/test",

        "/inner/.profile-oss",

        // Files.
        "/extensions/dist",
        "/extensions/boop/doop/dist",
        "/extensions/boop/out",
    };
    for (included) |input| try h.noIgnoreMatch(input);

    const excluded = [_][]const u8{
        "/extensions/dist/",
        "/extensions/boop/dist/test",
        "/extensions/boop/doop/dist/",
        "/extensions/boop/doop/dist/test",
        "/extensions/boop/doop/dist/test",

        "/extensions/out/test",
        "/extensions/boop/out/",
        "/extensions/boop/out/test",

        "/out/",
        "/out/test",
        "/out1/",
        "/out1/test",
        "/out2/",
        "/out2/test",

        "/.profile-oss",
    };
    for (excluded) |input| try h.ignoreMatch(input);
}

test "Parsing .gitignore files: various advanced constructs found in popular repos" {
    const allocator = std.testing.allocator;

    try runPattern(allocator,
        \\**/node_modules
        \\/packages/*/dist
    , &.{
        "/inner/packages/a/dist",
        "/inner/packages/abc/dist",
        "/inner/packages/abc/dist/test",

        "/packages/dist",
        "/packages/dist/test",
        "/packages/a/b/dist",
        "/packages/a/b/dist/test",
    }, &.{
        "/node_modules",
        "/test/node_modules",
        "/node_modules/test",
        "/test/node_modules/test",

        "/packages/a/dist",
        "/packages/abc/dist",
        "/packages/abc/dist/test",
    });

    try runPattern(allocator,
        \\.yarn/*
        \\# !.yarn/cache
        \\!.yarn/patches
        \\!.yarn/plugins
        \\!.yarn/releases
        \\!.yarn/sdks
        \\!.yarn/versions
    , &.{
        "/inner/.yarn/test",
        "/inner/.yarn/cache",

        "/.yarn/patches",
        "/.yarn/plugins",
        "/.yarn/releases",
        "/.yarn/sdks",
        "/.yarn/versions",
    }, &.{
        "/.yarn/test",
        "/.yarn/cache",
    });

    try runPattern(allocator,
        \\[._]*s[a-w][a-z]
        \\[._]s[a-w][a-z]
        \\*.un~
        \\*~
    , &.{
        "/.jaa",
    }, &.{
        "/~",
        "/abc~",
        "/inner/~",
        "/inner/abc~",
        "/.un~",
        "/a.un~",
        "/test/.un~",
        "/test/a.un~",
        "/.saa",
        "/....saa",
        "/._._sby",
        "/inner/._._sby",
        "/_swz",
    });

    // TODO: the rest of these, like upstream.
    try runPattern(allocator,
        \\*.pbxuser
        \\!default.pbxuser
        \\*.mode1v3
        \\!default.mode1v3
        \\*.mode2v3
        \\!default.mode2v3
        \\*.perspectivev3
        \\!default.perspectivev3
    , &.{}, &.{});

    try runPattern(allocator,
        \\[Dd]ebug/
        \\[Dd]ebugPublic/
        \\[Rr]elease/
        \\[Rr]eleases/
        \\*.[Mm]etrics.xml
        \\[Tt]est[Rr]esult*/
        \\[Bb]uild[Ll]og.*
        \\bld/
        \\[Bb]in/
        \\[Oo]bj/
        \\[Ll]og/
    , &.{}, &.{});

    try runPattern(allocator,
        \\Dockerfile*
        \\!/tests/bud/*/Dockerfile*
        \\!/tests/conformance/**/Dockerfile*
    , &.{}, &.{});

    try runPattern(allocator,
        \\*.pdf
        \\*.html
        \\!author_bio.html
        \\!colo.html
        \\!copyright.html
        \\!cover.html
        \\!ix.html
        \\!titlepage.html
        \\!toc.html
    , &.{}, &.{});

    try runPattern(allocator,
        \\/log/*
        \\/tmp/*
        \\!/log/.keep
        \\!/tmp/.keep
    , &.{}, &.{});
}

test "Parsing .gitignore files: child negation overrides parent ignore" {
    const allocator = std.testing.allocator;
    const parent = try IgnoreFile.init(allocator, ".myconfig\n", "/", null, false);
    defer parent.deinit();

    const child = try IgnoreFile.init(allocator, "!.myconfig/\n", "/", parent, false);
    defer child.deinit();

    // The directory should NOT be ignored (child negates parent).
    try std.testing.expect(!try child.isArbitraryPathIgnored("/.myconfig", true));
    // Files inside the directory should also not be ignored.
    try std.testing.expect(!try child.isArbitraryPathIgnored("/.myconfig/settings/test.md", false));

    // Parent should still ignore when the child has no negation.
    const child_without_negation = try IgnoreFile.init(allocator, "node_modules/\n", "/", parent, false);
    defer child_without_negation.deinit();
    try std.testing.expect(try child_without_negation.isArbitraryPathIgnored("/.myconfig", true));
    try std.testing.expect(try child_without_negation.isArbitraryPathIgnored("/.myconfig/settings/test.md", false));
}

test "Parsing .gitignore files: child negation overrides parent ignore for files" {
    const allocator = std.testing.allocator;
    const parent = try IgnoreFile.init(allocator, "*.log\n", "/", null, false);
    defer parent.deinit();

    const child = try IgnoreFile.init(allocator, "!important.log\n", "/", parent, false);
    defer child.deinit();

    try std.testing.expect(!try child.isArbitraryPathIgnored("/important.log", false));
    try std.testing.expect(try child.isArbitraryPathIgnored("/other.log", false));
}

test "Parsing .gitignore files: case-insensitive ignore files" {
    const allocator = std.testing.allocator;

    const f1 = "node_modules/\n";
    try (Harness{ .allocator = allocator, .contents = f1, .location = "/" }).noIgnoreMatch("/Node_Modules/");
    try (Harness{ .allocator = allocator, .contents = f1, .location = "/", .ignore_case = true }).ignoreMatch("/Node_Modules/");

    const f2 = "NODE_MODULES/\n";
    try (Harness{ .allocator = allocator, .contents = f2, .location = "/" }).noIgnoreMatch("/Node_Modules/");
    try (Harness{ .allocator = allocator, .contents = f2, .location = "/", .ignore_case = true }).ignoreMatch("/Node_Modules/");

    const f3 =
        \\temp/*
        \\!temp/keep
    ;
    try (Harness{ .allocator = allocator, .contents = f3, .location = "/" }).noIgnoreMatch("/TEMP/other");
    try (Harness{ .allocator = allocator, .contents = f3, .location = "/" }).ignoreMatch("/temp/KEEP");
    try (Harness{ .allocator = allocator, .contents = f3, .location = "/", .ignore_case = true }).ignoreMatch("/TEMP/other");
    try (Harness{ .allocator = allocator, .contents = f3, .location = "/", .ignore_case = true }).noIgnoreMatch("/TEMP/KEEP");
}

test "Parsing .gitignore files: a lone negation ignores nothing" {
    const allocator = std.testing.allocator;
    // Upstream drops negations that become an empty pattern, so the file has
    // no effect instead of matching every path.
    const h = Harness{ .allocator = allocator, .contents = "!\n", .location = "/" };

    try h.noIgnoreMatch("/anything.txt");
    try h.traverses("/anything.txt");
}

test "Parsing .gitignore files: updateContents keeps location and parent" {
    const allocator = std.testing.allocator;
    const parent = try IgnoreFile.init(allocator, "*.log\n", "/", null, false);
    defer parent.deinit();

    const child = try IgnoreFile.init(allocator, "", "/inner/", parent, false);
    defer child.deinit();
    try std.testing.expect(try child.isArbitraryPathIgnored("/inner/other.log", false));

    try child.updateContents("!other.log\n");
    try std.testing.expect(!try child.isArbitraryPathIgnored("/inner/other.log", false));
    try std.testing.expect(try child.isArbitraryPathIgnored("/inner/kept.log", false));
}
