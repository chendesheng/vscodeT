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
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe.root_module.linkSystemLibrary("onig", .{});

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

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

    setupTests(b, target, optimize, onig);
}

/// Translates the oniguruma C header into a Zig module. Zig 0.17 removed
/// `@cImport`, so C headers must be translated by the build system instead.
fn onigModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/basics/oniguruma.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });

    const module = translate.createModule();
    module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    module.linkSystemLibrary("onig", .{});
    return module;
}

fn setupTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, onig: *std.Build.Module) void {
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
    tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    tests.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    tests.root_module.linkSystemLibrary("onig", .{});

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
