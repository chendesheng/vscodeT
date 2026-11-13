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
        .{ .step = "example-flex", .path = "examples/flex.zig", .description = "Run the flex layout example" },
        .{ .step = "example-flex-toolbar", .path = "examples/flex_toolbar.zig", .description = "Run the flex toolbar example" },
        .{ .step = "example-flex-cards", .path = "examples/flex_cards.zig", .description = "Run the wrapping flex cards example" },
        .{ .step = "example-flex-columns", .path = "examples/flex_columns.zig", .description = "Run the nested flex column example" },
        .{ .step = "example-flex-reverse", .path = "examples/flex_reverse.zig", .description = "Run the flex reverse-direction example" },
        .{ .step = "example-overflow", .path = "examples/overflow.zig", .description = "Run the overflow example" },
        .{ .step = "example-borders", .path = "examples/borders.zig", .description = "Run the borders example" },
        .{ .step = "example-table", .path = "examples/table.zig", .description = "Run the table example" },
        .{ .step = "example-tree", .path = "examples/tree.zig", .description = "Run the tree example" },
        .{ .step = "example-styling", .path = "examples/styling.zig", .description = "Run the styling example" },
        .{ .step = "example-focus", .path = "examples/focus.zig", .description = "Run the interactive focus example" },
        .{ .step = "example-mouse", .path = "examples/mouse.zig", .description = "Run the interactive mouse example" },
        .{ .step = "example-mouse-events", .path = "examples/mouse_events.zig", .description = "Run the interactive mouse event log" },
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
