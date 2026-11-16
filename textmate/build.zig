const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const onig_paths = OnigPaths{
        .include_dir = b.option([]const u8, "onig-include", "Directory containing oniguruma.h") orelse "",
        .lib_dir = b.option([]const u8, "onig-lib", "Directory containing the oniguruma library") orelse "",
    };
    const onig = onigModule(b, target, optimize, onig_paths);

    const module = b.addModule("vscode_textmate", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("c_onig", onig);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("c_onig", onig);

    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the vscode-textmate port tests");
    test_step.dependOn(&run_tests.step);

    const inspect_module = b.createModule(.{
        .root_source_file = b.path("src/tests/inspect.zig"),
        .target = target,
        .optimize = optimize,
    });
    inspect_module.addImport("vscode_textmate", module);
    const inspect_exe = b.addExecutable(.{
        .name = "textmate-inspect",
        .root_module = inspect_module,
    });
    const run_inspect = b.addRunArtifact(inspect_exe);
    run_inspect.addPassthruArgs();
    const inspect_step = b.step("inspect", "Inspect TextMate tokenization rule stacks");
    inspect_step.dependOn(&run_inspect.step);
}

/// Translates the oniguruma C header into a Zig module. Zig 0.17 removed
/// `@cImport`, so the build system performs the translation.
const OnigPaths = struct {
    include_dir: []const u8 = "",
    lib_dir: []const u8 = "",
};

fn onigModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, paths: OnigPaths) *std.Build.Module {
    const include_dir = onigIncludeDir(b, paths) orelse @panic(
        "oniguruma.h not found; install oniguruma " ++
            "(macOS: brew install oniguruma, Debian/Ubuntu: apt install libonig-dev)",
    );

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/oniguruma.h"),
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
    "/opt/homebrew/include",
    "/usr/local/include",
    "/usr/include",
};

const onig_lib_candidates = [_][]const u8{
    "/opt/homebrew/lib",
    "/usr/local/lib",
    "/usr/lib/x86_64-linux-gnu",
    "/usr/lib64",
    "/usr/lib",
};

fn onigIncludeDir(b: *std.Build, paths: OnigPaths) ?[]const u8 {
    if (paths.include_dir.len > 0) {
        const header = std.fmt.allocPrint(b.allocator, "{s}/oniguruma.h", .{paths.include_dir}) catch @panic("OOM");
        if (std.Io.Dir.accessAbsolute(b.graph.io, header, .{})) |_| return paths.include_dir else |_| {}
    }
    for (onig_include_candidates) |dir| {
        const header = std.fmt.allocPrint(b.allocator, "{s}/oniguruma.h", .{dir}) catch @panic("OOM");
        if (std.Io.Dir.accessAbsolute(b.graph.io, header, .{})) |_| return dir else |_| {}
    }
    return null;
}

fn addOnigLibraryPath(b: *std.Build, module: *std.Build.Module, paths: OnigPaths) void {
    if (paths.lib_dir.len > 0) {
        module.addLibraryPath(.{ .cwd_relative = paths.lib_dir });
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
