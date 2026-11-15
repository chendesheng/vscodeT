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

    setupTests(b, target, optimize, onig, textmate, ui, markdown);
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
    const sources = patchedTextmateSources(b, dep);
    const onig_wrapper = b.createModule(.{
        .root_source_file = sources.path(b, "pkg/oniguruma/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    onig_wrapper.addImport("c_onig", onig);

    const module = b.createModule(.{
        .root_source_file = sources.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("oniguruma", onig_wrapper);
    return module;
}

/// Zig sources from the pinned `textmate` package that `root.zig` reaches.
const textmate_zig_sources = [_][]const u8{
    "src/ansi_terminal.zig",
    "src/atoms.zig",
    "src/config.zig",
    "src/grammar.zig",
    "src/parser.zig",
    "src/root.zig",
    "src/strings.zig",
    "src/theme.zig",
    "src/processor/dump_processor.zig",
    "src/processor/processor.zig",
    "src/processor/render_console.zig",
    "src/processor/render_html.zig",
    "src/resources/embedded.zig",
    "src/resources/resources.zig",
    "src/pkg/oniguruma/c.zig",
    "src/pkg/oniguruma/errors.zig",
    "src/pkg/oniguruma/init.zig",
    "src/pkg/oniguruma/main.zig",
    "src/pkg/oniguruma/regex.zig",
    "src/pkg/oniguruma/region.zig",
    "src/pkg/oniguruma/testing.zig",
    "src/pkg/oniguruma/types.zig",
};

/// Copies the package sources into the build cache so `scopes.zig` can be
/// replaced. The package evaluator never advances past selector characters it
/// does not understand (the bundled HTML grammars use `*` wildcards), which
/// hangs tokenization once such a grammar has been loaded. See
/// `src/support/textmateScopes.zig`.
fn patchedTextmateSources(b: *std.Build, dep: *std.Build.Dependency) std.Build.LazyPath {
    const sources = b.addWriteFiles();
    _ = sources.addCopyDirectory(dep.path("src/resources"), "resources", .{
        .exclude_extensions = &.{".zig"},
    });
    inline for (textmate_zig_sources) |path| {
        _ = sources.addCopyFile(dep.path(path), path["src/".len..]);
    }
    _ = sources.add("scopes.zig", @embedFile("src/support/textmateScopes.zig"));
    return sources.getDirectory();
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

fn setupTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, onig: *std.Build.Module, textmate: *std.Build.Module, ui: *std.Build.Module, markdown: *std.Build.Module) void {
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
}
