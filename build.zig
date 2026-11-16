const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const onig = onigModule(b, target, optimize);
    const textmate_dep = b.dependency("textmate", .{ .target = target, .optimize = optimize });
    const textmate = textmateModule(b, textmate_dep, target, optimize, onig);
    const ui_dep = b.dependency("ui", .{ .target = target, .optimize = optimize });
    const ui = ui_dep.module("ui");
    const markdown = markdownModule(b, target, optimize);
    const vscode_syntax = vscodeSyntaxAssets(b, target, optimize, textmate_dep);

    // We will also create a module for our other entry point, 'main.zig'.
    const exe = b.addExecutable(.{
        .name = "zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("oniguruma", onig);
    exe.root_module.addImport("textmate", textmate);
    exe.root_module.addImport("ui", ui);
    exe.root_module.addImport("markdown", markdown);
    exe.root_module.addImport("vscode-syntax", vscode_syntax);
    addOnigLibraryPath(b, exe.root_module);
    exe.root_module.linkSystemLibrary("onig", .{});

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    // run_cmd.step.dependOn(b.getInstallStep());

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    setupTests(b, target, optimize, onig, textmate, ui, markdown, vscode_syntax);
}

/// Builds the markdown module from the pinned CommonMark + GFM package.
///
/// The upstream package exposes no Zig module and its own build script also
/// builds its CLI and test executables. Only the parser and its `entities`
/// module are needed here, so the module is wired from the package sources.
fn markdownModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    const dep = b.dependency("markdown_zig", .{ .target = target, .optimize = optimize });
    const entities = b.createModule(.{
        .root_source_file = dep.path("src/entities.zig"),
        .target = target,
        .optimize = optimize,
    });
    const module = b.createModule(.{
        .root_source_file = dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("entities", entities);
    return module;
}

/// Installs a textmate module backed by this build's oniguruma module.
///
/// The upstream textmate package hardcodes the macOS Homebrew prefix in its
/// own build script. Wiring the package's sources here keeps the dependency
/// but lets both Linux and macOS find oniguruma through `onigModule`.
fn textmateModule(
    b: *std.Build,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    onig: *std.Build.Module,
) *std.Build.Module {
    const onig_wrapper = b.createModule(.{
        .root_source_file = dep.path("src/pkg/oniguruma/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    onig_wrapper.addImport("c_onig", onig);

    const module = b.createModule(.{
        .root_source_file = dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("oniguruma", onig_wrapper);
    return module;
}

const VscodeGrammar = struct {
    language: []const u8,
    scope: []const u8,
    path: []const u8,
};

/// Grammars taken from the VS Code checkout, mirroring the extensions those
/// languages ship in. Languages without a working VS Code grammar (zig, toml,
/// yaml) keep the pinned package's grammar.
const vscode_grammars = [_]VscodeGrammar{
    .{ .language = "json", .scope = "source.json", .path = "../vscode/extensions/json/syntaxes/JSON.tmLanguage.json" },
    .{ .language = "jsonc", .scope = "source.json.comments", .path = "../vscode/extensions/json/syntaxes/JSONC.tmLanguage.json" },
    .{ .language = "javascript", .scope = "source.js", .path = "../vscode/extensions/javascript/syntaxes/JavaScript.tmLanguage.json" },
    .{ .language = "javascriptreact", .scope = "source.js.jsx", .path = "../vscode/extensions/javascript/syntaxes/JavaScriptReact.tmLanguage.json" },
    .{ .language = "typescript", .scope = "source.ts", .path = "../vscode/extensions/typescript-basics/syntaxes/TypeScript.tmLanguage.json" },
    .{ .language = "typescriptreact", .scope = "source.tsx", .path = "../vscode/extensions/typescript-basics/syntaxes/TypeScriptReact.tmLanguage.json" },
    .{ .language = "python", .scope = "source.python", .path = "../vscode/extensions/python/syntaxes/MagicPython.tmLanguage.json" },
    .{ .language = "rust", .scope = "source.rust", .path = "../vscode/extensions/rust/syntaxes/rust.tmLanguage.json" },
    .{ .language = "go", .scope = "source.go", .path = "../vscode/extensions/go/syntaxes/go.tmLanguage.json" },
    .{ .language = "c", .scope = "source.c", .path = "../vscode/extensions/cpp/syntaxes/c.tmLanguage.json" },
    .{ .language = "cpp", .scope = "source.cpp", .path = "../vscode/extensions/cpp/syntaxes/cpp.tmLanguage.json" },
    .{ .language = "", .scope = "source.cpp.embedded.macro", .path = "../vscode/extensions/cpp/syntaxes/cpp.embedded.macro.tmLanguage.json" },
    .{ .language = "java", .scope = "source.java", .path = "../vscode/extensions/java/syntaxes/java.tmLanguage.json" },
    .{ .language = "html", .scope = "text.html.basic", .path = "../vscode/extensions/html/syntaxes/html.tmLanguage.json" },
    .{ .language = "", .scope = "text.html.derivative", .path = "../vscode/extensions/html/syntaxes/html-derivative.tmLanguage.json" },
    .{ .language = "css", .scope = "source.css", .path = "../vscode/extensions/css/syntaxes/css.tmLanguage.json" },
    .{ .language = "scss", .scope = "source.css.scss", .path = "../vscode/extensions/scss/syntaxes/scss.tmLanguage.json" },
    .{ .language = "markdown", .scope = "text.html.markdown", .path = "../vscode/extensions/markdown-basics/syntaxes/markdown.tmLanguage.json" },
    .{ .language = "shellscript", .scope = "source.shell", .path = "../vscode/extensions/shellscript/syntaxes/shell-unix-bash.tmLanguage.json" },
    .{ .language = "bash", .scope = "source.shell", .path = "../vscode/extensions/shellscript/syntaxes/shell-unix-bash.tmLanguage.json" },
};

fn fileExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}

/// Builds a module containing the VS Code grammars and Dark+ theme files
/// embedded from the upstream checkout. When the checkout is unavailable the
/// package's own Dark+ theme is used and the package grammars stay in effect.
fn vscodeSyntaxAssets(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    textmate_dep: *std.Build.Dependency,
) *std.Build.Module {
    const files = b.addWriteFiles();
    var source = std.array_list.Managed(u8).init(b.allocator);
    source.appendSlice(
        \\const std = @import("std");
        \\
        \\pub const Grammar = struct { language: []const u8, scope: []const u8, data: []const u8 };
        \\pub const grammars = [_]Grammar{
        \\
    ) catch @panic("OOM");

    for (vscode_grammars) |grammar| {
        if (!fileExists(b, grammar.path)) continue;
        const file_name = std.fs.path.basename(grammar.path);
        const dest = std.fmt.allocPrint(b.allocator, "grammars/{s}", .{file_name}) catch @panic("OOM");
        _ = files.addCopyFile(.{ .cwd_relative = grammar.path }, dest);
        const line = std.fmt.allocPrint(
            b.allocator,
            "    .{{ .language = \"{s}\", .scope = \"{s}\", .data = @embedFile(\"{s}\") }},\n",
            .{ grammar.language, grammar.scope, dest },
        ) catch @panic("OOM");
        source.appendSlice(line) catch @panic("OOM");
    }

    _ = files.add(
        "grammars/markdown-code-fences.tmLanguage.json",
        @embedFile("src/support/markdownCodeFences.tmLanguage.json"),
    );
    source.appendSlice(
        \\    .{ .language = "", .scope = "markdown.code.fences", .data = @embedFile("grammars/markdown-code-fences.tmLanguage.json") },
        \\};
        \\
        \\pub fn scopeForLanguage(language: []const u8) ?[]const u8 {
        \\    inline for (grammars) |grammar| {
        \\        if (grammar.language.len > 0 and std.mem.eql(u8, grammar.language, language)) return grammar.scope;
        \\    }
        \\    return null;
        \\}
        \\
    ) catch @panic("OOM");

    const dark_plus_path = "../vscode/extensions/theme-defaults/themes/dark_plus.json";
    const dark_vs_path = "../vscode/extensions/theme-defaults/themes/dark_vs.json";
    if (fileExists(b, dark_plus_path) and fileExists(b, dark_vs_path)) {
        _ = files.addCopyFile(.{ .cwd_relative = dark_plus_path }, "themes/dark_plus.json");
        _ = files.addCopyFile(.{ .cwd_relative = dark_vs_path }, "themes/dark_vs.json");
        source.appendSlice(
            \\pub const dark_plus = @embedFile("themes/dark_plus.json");
            \\pub const dark_vs = @embedFile("themes/dark_vs.json");
            \\pub fn themeData(name: []const u8) ?[]const u8 {
            \\    if (std.mem.eql(u8, name, "dark_plus.json")) return dark_plus;
            \\    if (std.mem.eql(u8, name, "dark_vs.json")) return dark_vs;
            \\    return null;
            \\}
            \\
        ) catch @panic("OOM");
    } else {
        _ = files.addCopyFile(textmate_dep.path("src/resources/themes/dark-plus.json"), "themes/dark_plus.json");
        source.appendSlice(
            \\pub const dark_plus = @embedFile("themes/dark_plus.json");
            \\pub fn themeData(name: []const u8) ?[]const u8 {
            \\    if (std.mem.eql(u8, name, "dark_plus.json")) return dark_plus;
            \\    return null;
            \\}
            \\
        ) catch @panic("OOM");
    }

    const root = files.add("syntax.zig", source.items);
    return b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
    });
}

/// Translates the oniguruma C header into a Zig module. Zig 0.17 removed
/// `@cImport`, so C headers must be translated by the build system instead.
///
/// Search the usual Linux and macOS install prefixes instead of assuming a
/// single Homebrew location.
fn onigModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    const include_dir = onigIncludeDir(b) orelse @panic(
        "oniguruma.h not found; install oniguruma " ++
            "(macOS: brew install oniguruma, Debian/Ubuntu: apt install libonig-dev)",
    );

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/support/oniguruma.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(.{ .cwd_relative = include_dir });

    const module = translate.createModule();
    module.addIncludePath(.{ .cwd_relative = include_dir });
    addOnigLibraryPath(b, module);
    module.linkSystemLibrary("onig", .{});
    return module;
}

const onig_include_candidates = [_][]const u8{
    "/opt/homebrew/include", // Homebrew on Apple Silicon
    "/usr/local/include", // Homebrew on Intel macOS and /usr/local installs
    "/usr/include",
};

const onig_lib_candidates = [_][]const u8{
    "/opt/homebrew/lib",
    "/usr/local/lib",
    "/usr/lib/x86_64-linux-gnu", // Debian/Ubuntu multiarch
    "/usr/lib64",
    "/usr/lib",
};

fn onigIncludeDir(b: *std.Build) ?[]const u8 {
    for (onig_include_candidates) |dir| {
        const header = std.fmt.allocPrint(b.allocator, "{s}/oniguruma.h", .{dir}) catch @panic("OOM");
        if (std.Io.Dir.accessAbsolute(b.graph.io, header, .{})) |_| return dir else |_| {}
    }
    return null;
}

fn addOnigLibraryPath(b: *std.Build, module: *std.Build.Module) void {
    for (onig_lib_candidates) |dir| {
        const names = [_][]const u8{ "libonig.so", "libonig.dylib", "libonig.a" };
        for (names) |name| {
            const lib = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ dir, name }) catch @panic("OOM");
            if (std.Io.Dir.accessAbsolute(b.graph.io, lib, .{})) |_| {
                module.addLibraryPath(.{ .cwd_relative = dir });
                return;
            } else |_| {}
        }
    }
}

fn setupTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, onig: *std.Build.Module, textmate: *std.Build.Module, ui: *std.Build.Module, markdown: *std.Build.Module, vscode_syntax: *std.Build.Module) void {
    const test_step = b.step("test", "Run all tests");

    const tests = b.addTest(.{
        .name = "tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("oniguruma", onig);
    tests.root_module.addImport("textmate", textmate);
    tests.root_module.addImport("ui", ui);
    tests.root_module.addImport("markdown", markdown);
    tests.root_module.addImport("vscode-syntax", vscode_syntax);
    addOnigLibraryPath(b, tests.root_module);
    tests.root_module.linkSystemLibrary("onig", .{});

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const ui_tests = b.addTest(.{
        .name = "ui_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ui/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ui_tests = b.addRunArtifact(ui_tests);
    test_step.dependOn(&run_ui_tests.step);

    const vscode_textmate_dep = b.dependency("vscode_textmate", .{
        .target = target,
        .optimize = optimize,
    });
    const vscode_textmate_tests = b.addTest(.{
        .name = "vscode_textmate_tests",
        .root_module = vscode_textmate_dep.module("vscode_textmate"),
    });
    const run_vscode_textmate_tests = b.addRunArtifact(vscode_textmate_tests);
    test_step.dependOn(&run_vscode_textmate_tests.step);
}
