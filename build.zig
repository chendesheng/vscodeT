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

    const watcher_only = b.option(bool, "watcher-only", "Build only the file-watcher tests") orelse false;
    const enable_fsevents = fseventsEnabled(b, target);
    const onig_paths = OnigPaths{
        .include_dir = b.option([]const u8, "onig-include", "Directory containing oniguruma.h"),
        .lib_dir = b.option([]const u8, "onig-lib", "Directory containing the oniguruma library"),
    };

    if (!watcher_only) {
        const onig = onigModule(b, target, optimize, onig_paths);

        const vscode_textmate_dep = b.dependency("vscode_textmate", .{
            .target = target,
            .optimize = optimize,
            .@"onig-include" = onig_paths.include_dir orelse "",
            .@"onig-lib" = onig_paths.lib_dir orelse "",
        });
        const vscode_textmate = vscode_textmate_dep.module("vscode_textmate");
        const ui_dep = b.dependency("ui", .{ .target = target, .optimize = optimize });
        const ui = ui_dep.module("ui");
        const zigimg_dep = b.dependency("zigimg", .{ .target = target, .optimize = optimize });
        const zigimg = zigimg_dep.module("zigimg");
        const markdown = markdownModule(b, target, optimize);
        const vscode_syntax = vscodeSyntaxAssets(b, target, optimize);
        const ghostty_vt = ghosttyVtModule(b, target);

        // We will also create a module for our other entry point, 'main.zig'.
        const exe = b.addExecutable(.{
            .name = "zig",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        const app_build_options = b.addOptions();
        app_build_options.addOption(bool, "e2e", false);
        app_build_options.addOption(bool, "fsevents", enable_fsevents);
        exe.root_module.addOptions("build_options", app_build_options);
        exe.root_module.addImport("oniguruma", onig);
        exe.root_module.addImport("vscode_textmate", vscode_textmate);
        exe.root_module.addImport("ui", ui);
        exe.root_module.addImport("zigimg", zigimg);
        exe.root_module.addImport("markdown", markdown);
        exe.root_module.addImport("vscode-syntax", vscode_syntax);
        exe.root_module.addImport("ghostty-vt", ghostty_vt);
        addOnigLibraryPath(b, exe.root_module, onig_paths);
        exe.root_module.linkSystemLibrary("onig", .{});
        linkPtyLibraries(exe.root_module, target);
        linkMacFrameworks(exe.root_module, target, enable_fsevents);

        // This declares intent for the executable to be installed into the
        // standard location when the user invokes the "install" step (the default
        // step when running `zig build`).
        b.installArtifact(exe);

        // This *creates* a Run step in the build graph, to be executed when another
        // step is evaluated that depends on it. The next line below will establish
        // such a dependency.
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.addPassthruArgs();

        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build run`
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);

        setupTests(b, target, optimize, onig, vscode_textmate, ui, markdown, vscode_syntax, ghostty_vt, onig_paths);
    }

    setupWatcherTests(b, target, optimize);
    setupExtensionHost(b);
}

/// The Node extension host is a runtime asset, not a Zig artifact: bundling it
/// needs Node and the `host/` npm dependencies. Keep it behind an explicit step
/// so `zig build` stays hermetic. The bundle always reads the pinned `vscode/`
/// submodule, which is the source the generated RPC table comes from.
fn setupExtensionHost(b: *std.Build) void {
    const host_step = b.step("host", "Bundle the Node extension host (host/dist/extensionHost.mjs)");
    const host_build = b.addSystemCommand(&.{ "node", "build.js" });
    host_build.setCwd(b.path("host"));
    host_step.dependOn(&host_build.step);
}

fn linkPtyLibraries(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    // glibc keeps forkpty in libutil; macOS exposes it through libSystem and
    // musl includes it in libc.
    if (target.result.os.tag == .linux and target.result.abi == .gnu) {
        module.linkSystemLibrary("util", .{});
    }
}

/// The FSEvents backend is selected on macOS when the host can link the
/// CoreServices framework. Cross-compiling a macOS watcher test from Linux
/// keeps the kqueue fallback so the CI type-check does not need an SDK.
fn fseventsEnabled(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .macos and b.graph.host.result.os.tag == .macos;
}

fn linkMacFrameworks(module: *std.Build.Module, target: std.Build.ResolvedTarget, enabled: bool) void {
    if (!enabled) return;
    _ = target;
    module.linkFramework("CoreServices", .{});
    module.linkFramework("CoreFoundation", .{});
}

fn ghosttyVtModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    // The workbench renders kitty images itself (see docs/terminal-ui.md);
    // the integrated-terminal engine still has no kitty-graphics support, so
    // keep the feature off here. Besides avoiding unused code, this keeps the
    // Wuffs C image decoder out of the build graph: it does not compile with
    // the MSVC-targeted Zig toolchain on Windows.
    //
    // Ghostty's SIMD path also needs libc++ and the simdutf/highway C++
    // sources, which the MSVC-targeted build does not supply. Use its
    // scalar fallback there; the other platforms keep SIMD enabled.
    const dep = b.lazyDependency("ghostty", .{
        .@"vt-features" = "-kitty-graphics",
        .simd = target.result.os.tag != .windows,
    }) orelse @panic("libghostty-vt dependency was not resolved");
    return dep.module("ghostty-vt");
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

const VscodeGrammar = struct {
    language: []const u8,
    scope: []const u8,
    /// Path in the pinned VS Code checkout.
    path: []const u8,
    /// Vendored copy for checkouts without the `vscode/` submodule.
    fallback_path: []const u8 = "",
};

/// Grammars taken from the VS Code checkout, mirroring the extensions those
/// languages ship in. `src/support/grammars` keeps vendored fallbacks for the
/// languages without a usable extension grammar (zig, toml, yaml) and for the
/// pinned Markdown grammar.
const vscode_grammars = [_]VscodeGrammar{
    .{ .language = "json", .scope = "source.json", .path = "vscode/extensions/json/syntaxes/JSON.tmLanguage.json" },
    .{ .language = "jsonc", .scope = "source.json.comments", .path = "vscode/extensions/json/syntaxes/JSONC.tmLanguage.json" },
    .{ .language = "javascript", .scope = "source.js", .path = "vscode/extensions/javascript/syntaxes/JavaScript.tmLanguage.json" },
    .{ .language = "javascriptreact", .scope = "source.js.jsx", .path = "vscode/extensions/javascript/syntaxes/JavaScriptReact.tmLanguage.json" },
    .{ .language = "typescript", .scope = "source.ts", .path = "vscode/extensions/typescript-basics/syntaxes/TypeScript.tmLanguage.json" },
    .{ .language = "typescriptreact", .scope = "source.tsx", .path = "vscode/extensions/typescript-basics/syntaxes/TypeScriptReact.tmLanguage.json" },
    .{ .language = "python", .scope = "source.python", .path = "vscode/extensions/python/syntaxes/MagicPython.tmLanguage.json" },
    .{ .language = "rust", .scope = "source.rust", .path = "vscode/extensions/rust/syntaxes/rust.tmLanguage.json" },
    .{ .language = "go", .scope = "source.go", .path = "vscode/extensions/go/syntaxes/go.tmLanguage.json" },
    .{ .language = "c", .scope = "source.c", .path = "vscode/extensions/cpp/syntaxes/c.tmLanguage.json" },
    .{ .language = "cpp", .scope = "source.cpp", .path = "vscode/extensions/cpp/syntaxes/cpp.tmLanguage.json" },
    .{ .language = "", .scope = "source.cpp.embedded.macro", .path = "vscode/extensions/cpp/syntaxes/cpp.embedded.macro.tmLanguage.json" },
    .{ .language = "java", .scope = "source.java", .path = "vscode/extensions/java/syntaxes/java.tmLanguage.json" },
    .{ .language = "html", .scope = "text.html.basic", .path = "vscode/extensions/html/syntaxes/html.tmLanguage.json" },
    .{ .language = "", .scope = "text.html.derivative", .path = "vscode/extensions/html/syntaxes/html-derivative.tmLanguage.json" },
    .{ .language = "css", .scope = "source.css", .path = "vscode/extensions/css/syntaxes/css.tmLanguage.json" },
    .{ .language = "scss", .scope = "source.css.scss", .path = "vscode/extensions/scss/syntaxes/scss.tmLanguage.json" },
    .{ .language = "markdown", .scope = "text.html.markdown", .path = "vscode/extensions/markdown-basics/syntaxes/markdown.tmLanguage.json", .fallback_path = "src/support/grammars/markdown.json" },
    .{ .language = "shellscript", .scope = "source.shell", .path = "vscode/extensions/shellscript/syntaxes/shell-unix-bash.tmLanguage.json" },
    .{ .language = "bash", .scope = "source.shell", .path = "vscode/extensions/shellscript/syntaxes/shell-unix-bash.tmLanguage.json" },
};

fn fileExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}

const VscodeLanguageConfiguration = struct {
    language: []const u8,
    /// Path in the pinned VS Code checkout.
    path: []const u8,
    /// Vendored copy for checkouts without `vscode`.
    fallback_path: []const u8 = "",
};

/// Language configurations from the VS Code extensions that contribute the
/// bundled languages. Upstream keeps them next to each extension manifest;
/// embedding them here lets the TUI consume the same comments, brackets,
/// auto-closing pairs, folding flag and indentation rules as VS Code.
const vscode_language_configurations = [_]VscodeLanguageConfiguration{
    .{ .language = "json", .path = "vscode/extensions/json/language-configuration.json", .fallback_path = "src/support/languageConfigurations/json.json" },
    .{ .language = "jsonc", .path = "vscode/extensions/json/language-configuration.json", .fallback_path = "src/support/languageConfigurations/json.json" },
    .{ .language = "javascript", .path = "vscode/extensions/javascript/javascript-language-configuration.json" },
    .{ .language = "javascriptreact", .path = "vscode/extensions/javascript/javascript-language-configuration.json" },
    .{ .language = "typescript", .path = "vscode/extensions/typescript-basics/language-configuration.json" },
    .{ .language = "typescriptreact", .path = "vscode/extensions/typescript-basics/language-configuration.json" },
    .{ .language = "python", .path = "vscode/extensions/python/language-configuration.json" },
    .{ .language = "rust", .path = "vscode/extensions/rust/language-configuration.json" },
    .{ .language = "go", .path = "vscode/extensions/go/language-configuration.json" },
    .{ .language = "c", .path = "vscode/extensions/cpp/language-configuration.json" },
    .{ .language = "cpp", .path = "vscode/extensions/cpp/language-configuration.json" },
    .{ .language = "java", .path = "vscode/extensions/java/language-configuration.json" },
    .{ .language = "html", .path = "vscode/extensions/html/language-configuration.json" },
    .{ .language = "css", .path = "vscode/extensions/css/language-configuration.json" },
    .{ .language = "scss", .path = "vscode/extensions/scss/language-configuration.json" },
    .{ .language = "markdown", .path = "vscode/extensions/markdown-basics/language-configuration.json" },
    .{ .language = "yaml", .path = "vscode/extensions/yaml/language-configuration.json" },
    .{ .language = "shellscript", .path = "vscode/extensions/shellscript/language-configuration.json" },
};

/// Builds a module containing the VS Code grammars and Dark+ theme files
/// embedded from the upstream checkout. When the checkout is unavailable the
/// package's own Dark+ theme is used and the package grammars stay in effect.
fn vscodeSyntaxAssets(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
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

    var missing_grammars: usize = 0;
    for (vscode_grammars) |grammar| {
        const source_path = if (fileExists(b, grammar.path))
            grammar.path
        else if (grammar.fallback_path.len > 0 and fileExists(b, grammar.fallback_path))
            grammar.fallback_path
        else {
            missing_grammars += 1;
            continue;
        };
        const file_name = std.fs.path.basename(source_path);
        const dest = std.fmt.allocPrint(b.allocator, "grammars/{s}", .{file_name}) catch @panic("OOM");
        _ = files.addCopyFile(.{ .cwd_relative = source_path }, dest);
        const line = std.fmt.allocPrint(
            b.allocator,
            "    .{{ .language = \"{s}\", .scope = \"{s}\", .data = @embedFile(\"{s}\") }},\n",
            .{ grammar.language, grammar.scope, dest },
        ) catch @panic("OOM");
        source.appendSlice(line) catch @panic("OOM");
    }
    if (missing_grammars > 0) {
        std.debug.print(
            "warning: {d} VS Code grammar(s) missing; run `git submodule update --init --depth 1 vscode` and rebuild for every language\n",
            .{missing_grammars},
        );
    }

    _ = files.add(
        "grammars/markdown-code-fences.tmLanguage.json",
        @embedFile("src/support/markdownCodeFences.tmLanguage.json"),
    );
    source.appendSlice(
        \\    .{ .language = "", .scope = "markdown.code.fences", .data = @embedFile("grammars/markdown-code-fences.tmLanguage.json") },
        \\
    ) catch @panic("OOM");

    // Languages without a usable VS Code grammar use vendored fallback
    // grammars under `src/support/grammars`.
    const fallback_grammars = [_]VscodeGrammar{
        .{ .language = "zig", .scope = "source.zig", .path = "src/support/grammars/zig.json" },
        .{ .language = "toml", .scope = "source.toml", .path = "src/support/grammars/toml.json" },
        .{ .language = "yaml", .scope = "source.yaml", .path = "src/support/grammars/yaml.json" },
    };
    for (fallback_grammars) |grammar| {
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

    source.appendSlice(
        \\};
        \\
        \\pub fn scopeForLanguage(language: []const u8) ?[]const u8 {
        \\    inline for (grammars) |grammar| {
        \\        if (grammar.language.len > 0 and std.mem.eql(u8, grammar.language, language)) return grammar.scope;
        \\    }
        \\    return null;
        \\}
        \\
        \\pub fn dataForScope(scope: []const u8) ?[]const u8 {
        \\    inline for (grammars) |grammar| {
        \\        if (std.mem.eql(u8, grammar.scope, scope)) return grammar.data;
        \\    }
        \\    return null;
        \\}
        \\
    ) catch @panic("OOM");

    source.appendSlice(
        \\pub const LanguageConfiguration = struct { language: []const u8, data: []const u8 };
        \\pub const language_configurations = [_]LanguageConfiguration{
        \\
    ) catch @panic("OOM");
    for (vscode_language_configurations) |configuration| {
        var path: ?[]const u8 = null;
        if (fileExists(b, configuration.path)) {
            path = configuration.path;
        } else if (configuration.fallback_path.len > 0 and fileExists(b, configuration.fallback_path)) {
            path = configuration.fallback_path;
        }
        const source_path = path orelse continue;
        const dest = std.fmt.allocPrint(b.allocator, "language-configurations/{s}.json", .{configuration.language}) catch @panic("OOM");
        _ = files.addCopyFile(.{ .cwd_relative = source_path }, dest);
        const line = std.fmt.allocPrint(
            b.allocator,
            "    .{{ .language = \"{s}\", .data = @embedFile(\"{s}\") }},\n",
            .{ configuration.language, dest },
        ) catch @panic("OOM");
        source.appendSlice(line) catch @panic("OOM");
    }
    source.appendSlice(
        \\};
        \\
        \\pub fn languageConfigurationData(language: []const u8) ?[]const u8 {
        \\    inline for (language_configurations) |configuration| {
        \\        if (std.mem.eql(u8, configuration.language, language)) return configuration.data;
        \\    }
        \\    return null;
        \\}
        \\
    ) catch @panic("OOM");

    const dark_plus_path = "vscode/extensions/theme-defaults/themes/dark_plus.json";
    const dark_vs_path = "vscode/extensions/theme-defaults/themes/dark_vs.json";
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
        _ = files.addCopyFile(.{ .cwd_relative = "src/support/themes/dark-plus.json" }, "themes/dark_plus.json");
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
const OnigPaths = struct {
    include_dir: ?[]const u8 = null,
    lib_dir: ?[]const u8 = null,
};

fn onigModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, paths: OnigPaths) *std.Build.Module {
    const include_dir = onigIncludeDir(b, paths) orelse @panic(
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
    addOnigLibraryPath(b, module, paths);
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

fn onigIncludeDir(b: *std.Build, paths: OnigPaths) ?[]const u8 {
    if (paths.include_dir) |dir| {
        const header = std.fmt.allocPrint(b.allocator, "{s}/oniguruma.h", .{dir}) catch @panic("OOM");
        if (std.Io.Dir.accessAbsolute(b.graph.io, header, .{})) |_| return dir else |_| {}
    }
    for (onig_include_candidates) |dir| {
        const header = std.fmt.allocPrint(b.allocator, "{s}/oniguruma.h", .{dir}) catch @panic("OOM");
        if (std.Io.Dir.accessAbsolute(b.graph.io, header, .{})) |_| return dir else |_| {}
    }
    return null;
}

fn addOnigLibraryPath(b: *std.Build, module: *std.Build.Module, paths: OnigPaths) void {
    if (paths.lib_dir) |dir| {
        module.addLibraryPath(.{ .cwd_relative = dir });
        return;
    }
    for (onig_lib_candidates) |dir| {
        const names = [_][]const u8{ "libonig.so", "libonig.dylib", "libonig.a", "onig.lib" };
        for (names) |name| {
            const lib = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ dir, name }) catch @panic("OOM");
            if (std.Io.Dir.accessAbsolute(b.graph.io, lib, .{})) |_| {
                module.addLibraryPath(.{ .cwd_relative = dir });
                return;
            } else |_| {}
        }
    }
}

fn setupWatcherTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) void {
    // Watcher-only tests: compile and run without the POSIX TUI. This root is
    // also used to cross-check the Linux/macOS/Windows backends on a host that
    // cannot run the other targets' tests.
    const watcher_module = b.createModule(.{
        .root_source_file = b.path("src/watcher_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const enable_fsevents = fseventsEnabled(b, target);
    const watcher_options = b.addOptions();
    watcher_options.addOption(bool, "fsevents", enable_fsevents);
    watcher_module.addOptions("build_options", watcher_options);
    linkMacFrameworks(watcher_module, target, enable_fsevents);
    const watcher_tests = b.addTest(.{
        .name = "watcher_tests",
        .root_module = watcher_module,
    });
    const run_watcher_tests = b.addRunArtifact(watcher_tests);
    const watcher_test_step = b.step("test-watcher", "Run file-watcher tests");
    watcher_test_step.dependOn(&run_watcher_tests.step);

    const check_watcher_step = b.step("check-watcher", "Compile the file-watcher tests without running them");
    check_watcher_step.dependOn(&watcher_tests.step);
}

fn createTestRootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    onig: *std.Build.Module,
    vscode_textmate: *std.Build.Module,
    ui: *std.Build.Module,
    markdown: *std.Build.Module,
    vscode_syntax: *std.Build.Module,
    ghostty_vt: *std.Build.Module,
    onig_paths: OnigPaths,
    bench: bool,
    e2e: bool,
    bench_file: []const u8,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("oniguruma", onig);
    module.addImport("vscode_textmate", vscode_textmate);
    module.addImport("ui", ui);
    const zigimg_dep = b.dependency("zigimg", .{ .target = target, .optimize = optimize });
    module.addImport("zigimg", zigimg_dep.module("zigimg"));
    module.addImport("markdown", markdown);
    module.addImport("vscode-syntax", vscode_syntax);
    module.addImport("ghostty-vt", ghostty_vt);
    addOnigLibraryPath(b, module, onig_paths);
    module.linkSystemLibrary("onig", .{});
    linkPtyLibraries(module, target);

    const build_options = b.addOptions();
    build_options.addOption(bool, "bench", bench);
    build_options.addOption(bool, "e2e", e2e);
    build_options.addOption([]const u8, "bench_file", bench_file);
    const enable_fsevents = fseventsEnabled(b, target);
    build_options.addOption(bool, "fsevents", enable_fsevents);
    module.addOptions("build_options", build_options);
    linkMacFrameworks(module, target, enable_fsevents);
    return module;
}

fn setupTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, onig: *std.Build.Module, vscode_textmate: *std.Build.Module, ui: *std.Build.Module, markdown: *std.Build.Module, vscode_syntax: *std.Build.Module, ghostty_vt: *std.Build.Module, onig_paths: OnigPaths) void {
    const test_step = b.step("test", "Run all tests");
    const bench_file = b.option(
        []const u8,
        "bench-file",
        "File opened by the benchmark tests (default src/tui/app.zig)",
    ) orelse "src/tui/app.zig";

    const tests = b.addTest(.{
        .name = "tests",
        .root_module = createTestRootModule(
            b,
            target,
            optimize,
            onig,
            vscode_textmate,
            ui,
            markdown,
            vscode_syntax,
            ghostty_vt,
            onig_paths,
            false,
            false,
            bench_file,
        ),
    });

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // Focused runner for the editor core (`src/vs/editor/common/core`).
    const core_tests = b.addTest(.{
        .name = "core_tests",
        .root_module = tests.root_module,
        .filters = &.{"common.core."},
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    const core_test_step = b.step("test-core", "Run editor core tests");
    core_test_step.dependOn(&run_core_tests.step);

    // Focused runner for the editor view-part suites. The full suite can block
    // in unrelated long-running search tests on some hosts.
    const view_tests = b.addTest(.{
        .name = "view_tests",
        .root_module = tests.root_module,
        .filters = &.{ "block decorations", "View:", "TerminalViewHost", "FindController:", "margin:", "Editor:", "stickyScroll", "Statusbar", "activityBar", "tabBar", "Workbench: right click", "breadcrumbs", "breadcrumb", "Workbench: inactive breadcrumbs", "status bar context menu", "status bar escape", "tab context menu", "content widgets", "overlay widgets", "tab overflow", "tab close button", "view pane header", "hiding the tab row", "snippet placeholder navigation", "top inset reserves", "find bar reserves", "addExtraSpaceOnTop", "input history", "replace input history", "findOnType and closeOnResult", "seedSearchStringFromSelection", "autoFindInSelection", "find history can be disabled", "dragging the sash", "moved blocks create", "hide unchanged regions", "inline mode", "inline mode hides unchanged", "inline mode surfaces moved", "inline mode adds character", "closes to the right", "splits the captured tab", "closes saved tabs", "keeps dirty tabs", "duplicate tab", "split duplicates", "split copy shares", "editor group focus", "new group below", "move and duplicate editor group", "move editor into group", "splitEditorToRightGroup creates", "directional split commands", "splitEditor follows openSideBySideDirection", "directional group navigation", "closing the last tab", "dragging a tab", "dropping a tab", "openPath reveals", "serialize and restore multiple", "cell borders" },
    });
    const run_view_tests = b.addRunArtifact(view_tests);
    const view_test_step = b.step("test-view", "Run editor view-part tests");
    view_test_step.dependOn(&run_view_tests.step);

    // Focused runner for the native Vim and editor-history suites. The full
    // suite occasionally blocks in unrelated long-running search tests.
    const vim_tests = b.addTest(.{
        .name = "vim_tests",
        .root_module = tests.root_module,
        .filters = &.{ "Vim:", "Vim runtime", "historyService:", "TextEditorPaneSelection", "TokenizationUndo" },
    });
    const run_vim_tests = b.addRunArtifact(vim_tests);
    const vim_test_step = b.step("test-vim", "Run Vim and editor-history tests");
    vim_test_step.dependOn(&run_vim_tests.step);

    // Focused runner for the native Helix editing suite.
    const helix_tests = b.addTest(.{
        .name = "helix_tests",
        .root_module = tests.root_module,
        .filters = &.{"Helix"},
    });
    const run_helix_tests = b.addRunArtifact(helix_tests);
    const helix_test_step = b.step("test-helix", "Run Helix editing tests");
    helix_test_step.dependOn(&run_helix_tests.step);

    // Terminal-only test root: keeps the integrated-terminal tests runnable
    // without compiling the whole editor. `zig build test` covers them too.
    const terminal_tests = b.addTest(.{
        .name = "terminal_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/terminal_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    terminal_tests.root_module.addImport("ui", ui);
    terminal_tests.root_module.addImport("ghostty-vt", ghostty_vt);
    linkPtyLibraries(terminal_tests.root_module, target);
    const run_terminal_tests = b.addRunArtifact(terminal_tests);
    const terminal_test_step = b.step("test-terminal", "Run integrated-terminal tests");
    terminal_test_step.dependOn(&run_terminal_tests.step);

    // The Node extension-host interop test needs Node and the esbuild bundle
    // in host/dist. Keep it out of the hermetic `test` step;
    // docs/extensions.md defines this target. The build option `e2e` replaces
    // the old environment gate.
    const e2e_tests = b.addTest(.{
        .name = "e2e_tests",
        .root_module = createTestRootModule(
            b,
            target,
            optimize,
            onig,
            vscode_textmate,
            ui,
            markdown,
            vscode_syntax,
            ghostty_vt,
            onig_paths,
            false,
            true,
            bench_file,
        ),
        .filters = &.{"Extensions:"},
    });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    const e2e_test_step = b.step("test-e2e", "Run the extension-host interop tests");
    e2e_test_step.dependOn(&run_e2e_tests.step);

    const markdown_tests = b.addTest(.{
        .name = "markdown_tests",
        .root_module = tests.root_module,
        .filters = &.{"markdown"},
    });
    const run_markdown_tests = b.addRunArtifact(markdown_tests);
    const markdown_test_step = b.step("test-markdown", "Run markdown/TextMate syntax tests");
    markdown_test_step.dependOn(&run_markdown_tests.step);

    // Debug-build performance harness for the file-open/edit hot paths. The
    // tests are skipped in the normal suite unless this step enables them.
    const bench_tests = b.addTest(.{
        .name = "open_bench",
        .root_module = createTestRootModule(
            b,
            target,
            optimize,
            onig,
            vscode_textmate,
            ui,
            markdown,
            vscode_syntax,
            ghostty_vt,
            onig_paths,
            true,
            false,
            bench_file,
        ),
        .filters = &.{"benchmark:"},
    });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    const bench_test_step = b.step("bench-open", "Run the Debug open/edit benchmarks");
    bench_test_step.dependOn(&run_bench_tests.step);

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
        .@"onig-include" = onig_paths.include_dir orelse "",
        .@"onig-lib" = onig_paths.lib_dir orelse "",
    });
    const vscode_textmate_tests = b.addTest(.{
        .name = "vscode_textmate_tests",
        .root_module = vscode_textmate_dep.module("vscode_textmate"),
    });
    const run_vscode_textmate_tests = b.addRunArtifact(vscode_textmate_tests);
    test_step.dependOn(&run_vscode_textmate_tests.step);
}
