const std = @import("std");
const Module = std.Build.Module;

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

    // We will also create a module for our other entry point, 'main.zig'.
    const exe = b.addExecutable(.{
        .name = "zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const tree_sitter = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("tree-sitter", tree_sitter.module("tree_sitter"));

    // tree sitter grammars
    const tree_sitter_zig = b.dependency("tree_sitter_zig", .{
        .target = target,
        .optimize = optimize,
    });
    // exe.linkLibrary(tree_sitter_zig.artifact("tree-sitter-zig"));
    exe.root_module.addImport("tree-sitter-zig", tree_sitter_zig.module("tree-sitter-zig"));

    const tree_sitter_typescript = b.dependency("tree_sitter_typescript", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("tree-sitter-typescript", tree_sitter_typescript.module("tree-sitter-typescript"));

    linkOnig(exe);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    // run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    // if (b.args) |args| {
    // run_cmd.addArgs(args);
    // }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    setupTests(b, target, optimize, &exe.root_module.import_table);
}

fn setupTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, deps: *std.StringArrayHashMapUnmanaged(*Module)) void {
    const test_step = b.step("test", "Run all tests");

    const t = b.addTest(
        .{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }) },
    );

    var iter = deps.iterator();
    while (iter.next()) |entry| {
        t.root_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
    }

    linkOnig(t);

    const run_t = b.addRunArtifact(t);
    test_step.dependOn(&run_t.step);
}

fn linkOnig(t: *std.Build.Step.Compile) void {
    t.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    t.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    t.linkSystemLibrary("onig");
}
