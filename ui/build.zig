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

    // Filtered stress-only run for CI reports. The full suite also includes
    // these cases; this step just gives the report a small, named workload.
    const stress_tests = b.addTest(.{
        .name = "ui_stress_tests",
        .root_module = tests.root_module,
        .filters = &.{"stress:"},
    });
    const run_stress_tests = b.addRunArtifact(stress_tests);
    const stress_step = b.step("stress", "Run the ui library stress tests");
    stress_step.dependOn(&run_stress_tests.step);

    const bench_exe = b.addExecutable(.{
        .name = "ui-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/run.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench_exe.root_module.addImport("ui", ui);
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_args = b.option(
        []const u8,
        "bench-args",
        "Extra arguments for ui-bench (for example -Dbench-args=\"--runs 3 --markdown\")",
    ) orelse "";
    var bench_args_it = std.mem.tokenizeScalar(u8, bench_args, ' ');
    while (bench_args_it.next()) |arg| run_bench.addArg(arg);
    const bench_step = b.step("bench", "Run the UI stress benchmarks");
    bench_step.dependOn(&run_bench.step);
    // Compile the benchmark as part of `test` so it cannot rot; do not run it.
    test_step.dependOn(&bench_exe.step);

    const examples = [_]struct {
        step: []const u8,
        path: []const u8,
        description: []const u8,
    }{
        .{ .step = "example-hello", .path = "examples/hello.zig", .description = "Run the hello example" },
        .{ .step = "example-list", .path = "examples/list.zig", .description = "Run the list example" },
        .{ .step = "example-layout", .path = "examples/layout.zig", .description = "Run the layout example" },
        .{ .step = "example-flex", .path = "examples/flex.zig", .description = "Run the flex layout example" },
        .{ .step = "example-flex-toolbar", .path = "examples/flex_toolbar.zig", .description = "Run the flex toolbar example" },
        .{ .step = "example-flex-cards", .path = "examples/flex_cards.zig", .description = "Run the wrapping flex cards example" },
        .{ .step = "example-flex-columns", .path = "examples/flex_columns.zig", .description = "Run the nested flex column example" },
        .{ .step = "example-flex-reverse", .path = "examples/flex_reverse.zig", .description = "Run the flex reverse-direction example" },
        .{ .step = "example-width-bounds", .path = "examples/width_bounds.zig", .description = "Run the block width-bounds example" },
        .{ .step = "example-flex-bounds", .path = "examples/flex_bounds.zig", .description = "Run the flex width-bounds example" },
        .{ .step = "example-overflow", .path = "examples/overflow.zig", .description = "Run the overflow example" },
        .{ .step = "example-wrap", .path = "examples/wrap.zig", .description = "Run the text wrapping example" },
        .{ .step = "example-borders", .path = "examples/borders.zig", .description = "Run the borders example" },
        .{ .step = "example-table", .path = "examples/table.zig", .description = "Run the table example" },
        .{ .step = "example-markdown", .path = "examples/markdown.zig", .description = "Run the markdown example" },
        .{ .step = "example-tree", .path = "examples/tree.zig", .description = "Run the tree example" },
        .{ .step = "example-styling", .path = "examples/styling.zig", .description = "Run the styling example" },
        .{ .step = "example-css", .path = "examples/css.zig", .description = "Run the class/cascade example" },
        .{ .step = "example-focus", .path = "examples/focus.zig", .description = "Run the interactive focus example" },
        .{ .step = "example-mouse", .path = "examples/mouse.zig", .description = "Run the interactive mouse example" },
        .{ .step = "example-mouse-events", .path = "examples/mouse_events.zig", .description = "Run the interactive mouse event log" },
        .{ .step = "example-todo", .path = "examples/todo.zig", .description = "Run the interactive TodoMVC example" },
        .{ .step = "example-context-menu", .path = "examples/context_menu.zig", .description = "Run the native context menu example" },
    };

    const all_examples = b.step("examples", "Open the fullscreen examples gallery");
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

        // Compile the examples as part of `test` so they cannot rot.
        test_step.dependOn(&exe.step);
    }

    // `zig build examples` opens the fullscreen gallery; the individual
    // `example-*` steps above still run one scene directly.
    const gallery_exe = b.addExecutable(.{
        .name = "examples-gallery",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/gallery.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gallery_exe.root_module.addImport("ui", ui);
    const run_gallery = b.addRunArtifact(gallery_exe);
    all_examples.dependOn(&run_gallery.step);
    test_step.dependOn(&gallery_exe.step);
}
