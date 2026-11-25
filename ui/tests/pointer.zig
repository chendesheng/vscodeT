const std = @import("std");
const ui = @import("ui");
const Pointer = ui.pointer.Pointer;
const name = ui.pointer.name;
const writeShape = ui.pointer.writeShape;
const State = ui.pointer.State;

test "pointer: names use the CSS cursor spelling" {
    try std.testing.expectEqualStrings("default", name(.default));
    try std.testing.expectEqualStrings("e-resize", name(.e_resize));
    try std.testing.expectEqualStrings("nesw-resize", name(.nesw_resize));
    try std.testing.expectEqualStrings("vertical-text", name(.vertical_text));
    try std.testing.expectEqualStrings("zoom-in", name(.zoom_in));

    // The kitty protocol defines 30 required CSS shape names.
    try std.testing.expectEqual(@as(usize, 30), @typeInfo(Pointer).@"enum".field_names.len);
}

test "pointer: encodes OSC 22 with ST" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeShape(&out.writer, .pointer);
    try writeShape(&out.writer, .text);
    try std.testing.expectEqualStrings("\x1b]22;pointer\x1b\\\x1b]22;text\x1b\\", out.written());
}

test "pointer: state deduplicates shapes and resets" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var state: State = .{};

    // Default is the initial emitted state: no sequence at startup.
    try state.update(&out.writer, .default);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);

    try state.update(&out.writer, .text);
    try std.testing.expectEqualStrings("\x1b]22;text\x1b\\", out.written());

    out.clearRetainingCapacity();
    try state.update(&out.writer, .text);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);

    try state.update(&out.writer, .pointer);
    try std.testing.expectEqualStrings("\x1b]22;pointer\x1b\\", out.written());

    out.clearRetainingCapacity();
    try state.reset(&out.writer);
    try std.testing.expectEqualStrings("\x1b]22;default\x1b\\", out.written());

    out.clearRetainingCapacity();
    try state.reset(&out.writer);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}
