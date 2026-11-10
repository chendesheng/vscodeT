const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ui = b.addModule("ui", .{
        .root_source_file = b.path("ui.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the ui library tests");
    test_step.dependOn(&run_tests.step);

    const examples = [_]struct {
        step: []const u8,
        path: []const u8,
        description: []const u8,
    }{
        .{ .step = "example-hello", .path = "examples/hello.zig", .description = "Run the hello example" },
        .{ .step = "example-list", .path = "examples/list.zig", .description = "Run the list example" },
        .{ .step = "example-layout", .path = "examples/layout.zig", .description = "Run the layout example" },
    };

    const all_examples = b.step("examples", "Run all ui examples");
    inline for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.step,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("ui", ui);

        const run = b.addRunArtifact(exe);
        const step = b.step(example.step, example.description);
        step.dependOn(&run.step);
        all_examples.dependOn(&run.step);

        // Compile the examples as part of `test` so they cannot rot.
        test_step.dependOn(&exe.step);
    }
}
